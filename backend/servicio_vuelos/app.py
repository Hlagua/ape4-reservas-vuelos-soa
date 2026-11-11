"""Servicio de Vuelos (proveedor): consulta de vuelos, mapa de asientos y control de asientos.

Es el único dueño del esquema `vuelos`. Control de concurrencia de asientos:
  - Un asiento sin fila en `vuelos.asientos` está disponible.
  - Al seleccionar un asiento se crea una RETENCIÓN temporal (RETENCION_MINUTOS).
  - Al confirmar la reserva el asiento pasa a OCUPADO.
  - La clave primaria (vuelo_id, asiento) impide que dos usuarios tengan el mismo
    asiento: si dos clientes lo intentan a la vez, SQL Server acepta solo a uno.
"""
import json
import threading
import uuid
from datetime import datetime, timedelta

from flask import jsonify, request
from sqlalchemy import bindparam, text
from sqlalchemy.exc import IntegrityError

from common import config
from common.app_base import crear_app
from common.clientes import no_admin, requerir_admin, requerir_clave_servicio, requerir_token, usuario_opcional
from common.db import engine
from common.errores import ErrorApi, leer_json
from servicio_vuelos.cabina import AVION_PREDETERMINADO, CABINAS as CABINAS_BASE, construir_clases, crear_cabina

app = crear_app(__name__, "Vuelos", "Consulta de vuelos, mapa de asientos y control de asientos", usa_bd=True)

MAX_ASIENTOS_POR_USUARIO = config.MAX_ASIENTOS
COLUMNAS = "id, codigo, aerolinea, avion, origen, destino, fecha_salida, fecha_llegada, precio, asientos_totales"
# Filas que cuentan como no disponibles (las retenciones vencidas se ignoran)
ASIENTO_ACTIVO = "(estado <> 'RETENIDO' OR expira_en > LOCALTIMESTAMP)"


def vuelo_a_dict(fila):
    datos = {
        "id": fila.id,
        "codigo": fila.codigo,
        "aerolinea": fila.aerolinea,
        "avion": fila.avion,
        "origen": fila.origen,
        "destino": fila.destino,
        "fecha_salida": fila.fecha_salida.isoformat(timespec="minutes"),
        "fecha_llegada": fila.fecha_llegada.isoformat(timespec="minutes"),
        "precio": float(fila.precio),
        "asientos_totales": fila.asientos_totales,
    }
    if hasattr(fila, "asientos_disponibles"):
        datos["asientos_disponibles"] = fila.asientos_disponibles
    return datos


def entero_positivo(valor, campo):
    try:
        numero = int(valor)
    except (TypeError, ValueError):
        raise ErrorApi(f"El campo '{campo}' debe ser un número entero", 400)
    if numero < 1:
        raise ErrorApi(f"El campo '{campo}' debe ser mayor a 0", 400)
    return numero


def buscar_vuelo(con, vuelo_id, bloquear=False):
    """Con bloquear=True la fila del vuelo queda bloqueada (FOR UPDATE) hasta el fin de la transacción.

    Toda operación que cambia asientos bloquea primero el vuelo: así los cambios de un mismo
    vuelo se aplican en orden y el trigger que actualiza asientos_disponibles no genera interbloqueos.
    """
    sql = f"SELECT {COLUMNAS} FROM vuelos.vuelos WHERE id = :id" + (" FOR UPDATE" if bloquear else "")
    fila = con.execute(text(sql), {"id": vuelo_id}).first()
    if not fila:
        raise ErrorApi("Vuelo no encontrado", 404)
    return fila


def liberar_vencidas(vuelo_id):
    """Borra las retenciones vencidas del vuelo para que asientos_disponibles quede al día."""
    consulta = {"v": vuelo_id}
    with engine.begin() as con:
        hay = con.execute(text("""
            SELECT 1 FROM vuelos.asientos
            WHERE vuelo_id = :v AND estado = 'RETENIDO' AND expira_en <= LOCALTIMESTAMP LIMIT 1
        """), consulta).first()
        if hay and buscar_vuelo(con, vuelo_id, bloquear=True):
            con.execute(text("""
                DELETE FROM vuelos.asientos
                WHERE vuelo_id = :v AND estado = 'RETENIDO' AND expira_en <= LOCALTIMESTAMP
            """), consulta)


def validar_asiento(asiento, cab):
    """Valida que el asiento exista en la cabina del avión del vuelo."""
    asiento = str(asiento or "").strip().upper()
    if asiento not in cab.asientos:
        raise ErrorApi(f"El asiento '{asiento}' no existe en el avión {cab.avion}", 404)
    return asiento


def validar_lista_asientos(data, cab):
    asientos = data.get("asientos")
    if not isinstance(asientos, list) or not asientos:
        raise ErrorApi("Debe enviar la lista de asientos", 400)
    asientos = [validar_asiento(a, cab) for a in asientos]
    if len(set(asientos)) != len(asientos):
        raise ErrorApi("Hay asientos repetidos", 400)
    return asientos


# ---------- Consulta de vuelos ----------

@app.get("/api/vuelos")
def buscar_vuelos():
    """Buscar vuelos disponibles
    ---
    tags: [Vuelos]
    parameters:
      - {in: query, name: origen, type: string, example: Quito}
      - {in: query, name: destino, type: string, example: Guayaquil}
      - {in: query, name: fecha, type: string, format: date, description: "YYYY-MM-DD"}
      - {in: query, name: pasajeros, type: integer, description: Asientos mínimos disponibles}
    responses:
      200: {description: Lista de vuelos que cumplen el filtro}
      400: {description: Parámetros inválidos}
    """
    condiciones = ["fecha_salida > LOCALTIMESTAMP"]
    parametros = {}
    if request.args.get("origen"):
        condiciones.append("origen = :origen")
        parametros["origen"] = request.args["origen"].strip()
    if request.args.get("destino"):
        condiciones.append("destino = :destino")
        parametros["destino"] = request.args["destino"].strip()
    if request.args.get("fecha"):
        try:
            parametros["fecha"] = datetime.strptime(request.args["fecha"], "%Y-%m-%d").date()
        except ValueError:
            raise ErrorApi("La fecha debe tener el formato YYYY-MM-DD", 400)
        condiciones.append("CAST(fecha_salida AS DATE) = :fecha")
    if request.args.get("pasajeros"):
        parametros["pasajeros"] = entero_positivo(request.args["pasajeros"], "pasajeros")
        if parametros["pasajeros"] > MAX_ASIENTOS_POR_USUARIO:
            raise ErrorApi(f"Máximo {MAX_ASIENTOS_POR_USUARIO} pasajeros", 400)
        condiciones.append("asientos_disponibles >= :pasajeros")

    with engine.connect() as con:
        filas = con.execute(text(f"""
            SELECT * FROM (
                -- Disponibilidad en vivo: descuenta solo las retenciones vigentes
                SELECT {COLUMNAS}, asientos_totales - (SELECT COUNT(*) FROM vuelos.asientos a
                                      WHERE a.vuelo_id = v.id AND {ASIENTO_ACTIVO}) AS asientos_disponibles
                FROM vuelos.vuelos v
            ) x
            WHERE {' AND '.join(condiciones)}
            ORDER BY fecha_salida
            LIMIT 100
        """), parametros).all()
    return jsonify({"total": len(filas), "vuelos": [vuelo_a_dict(f) for f in filas]})


@app.get("/api/vuelos/ciudades")
def listar_ciudades():
    """Listar ciudades de origen y destino
    ---
    tags: [Vuelos]
    responses:
      200: {description: Ciudades disponibles}
    """
    with engine.connect() as con:
        origenes = con.execute(text("SELECT DISTINCT origen FROM vuelos.vuelos ORDER BY origen")).scalars().all()
        destinos = con.execute(text("SELECT DISTINCT destino FROM vuelos.vuelos ORDER BY destino")).scalars().all()
    return jsonify({"origenes": origenes, "destinos": destinos})


# ---------- Catálogos: ciudades, aerolíneas y aviones (los crea el administrador) ----------

_cabinas = {}
_candado = threading.Lock()


def cargar_cabinas():
    """Lee los aviones de la base (tabla vuelos.aviones) y arma la cabina de cada uno."""
    with engine.connect() as con:
        filas = con.execute(text("SELECT nombre, clases FROM vuelos.aviones ORDER BY total_asientos DESC")).all()
    nuevas = {f.nombre: crear_cabina(f.nombre, f.clases) for f in filas}
    with _candado:
        _cabinas.clear()
        _cabinas.update(nuevas)
    return nuevas


def cabina(avion):
    """Cabina del avión del vuelo. Un avión desconocido usa la cabina predeterminada (A340-600)."""
    cab = _cabinas.get(avion) or cargar_cabinas().get(avion)
    return cab or CABINAS_BASE.get(avion) or CABINAS_BASE[AVION_PREDETERMINADO]


def catalogo_ciudades(con):
    return con.execute(text("SELECT nombre FROM vuelos.ciudades ORDER BY nombre")).scalars().all()


def catalogo_aerolineas(con):
    return [{"nombre": f.nombre, "codigo": f.codigo} for f in con.execute(text(
        "SELECT nombre, codigo FROM vuelos.aerolineas ORDER BY nombre"))]


@app.get("/api/vuelos/catalogos")
def listar_catalogos():
    """Ciudades (con coordenadas para el mapa), aerolíneas y aviones registrados
    ---
    tags: [Catálogos]
    responses:
      200: {description: Catálogos}
    """
    with engine.connect() as con:
        ciudades, aerolineas = catalogo_ciudades(con), catalogo_aerolineas(con)
        coordenadas = {f.nombre: [float(f.latitud), float(f.longitud)] for f in con.execute(text(
            "SELECT nombre, latitud, longitud FROM vuelos.ciudades WHERE latitud IS NOT NULL AND longitud IS NOT NULL"))}
    return jsonify({"ciudades": ciudades, "coordenadas": coordenadas, "aerolineas": aerolineas,
                    "aviones": [c.resumen() for c in cargar_cabinas().values()]})


@app.get("/api/vuelos/aviones")
def listar_aviones():
    """Tipos de avión con su número de asientos por clase
    ---
    tags: [Catálogos]
    responses:
      200: {description: Aviones disponibles para crear vuelos}
    """
    return jsonify({"aviones": [c.resumen() for c in cargar_cabinas().values()]})


SIMBOLOS_NOMBRE = " .'-"


def nombre_catalogo(data, campo, etiqueta, letras_solo=True):
    valor = " ".join(str(data.get(campo) or "").split())
    if not 2 <= len(valor) <= 60:
        raise ErrorApi("Datos inválidos", 400, {campo: f"{etiqueta} debe tener entre 2 y 60 caracteres"})
    if letras_solo and not all(c.isalpha() or c in SIMBOLOS_NOMBRE for c in valor):
        raise ErrorApi("Datos inválidos", 400, {campo: f"{etiqueta} solo admite letras y espacios"})
    return valor


def ya_existe(tabla, nombre):
    with engine.connect() as con:
        return con.execute(text(f"SELECT 1 FROM vuelos.{tabla} WHERE lower(nombre) = lower(:n)"), {"n": nombre}).first()


def insertar_unico(sql, parametros, mensaje_repetido, campo):
    try:
        with engine.begin() as con:
            con.execute(text(sql), parametros)
    except IntegrityError:
        raise ErrorApi(mensaje_repetido, 409, {campo: mensaje_repetido})


@app.post("/api/vuelos/ciudades")
def crear_ciudad():
    """[Administrador] Registrar una ciudad (sirve como origen y como destino)
    ---
    tags: [Catálogos]
    security: [{Bearer: []}]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [nombre]
          properties:
            nombre: {type: string, example: Esmeraldas}
            latitud: {type: number, example: 0.9592, description: "Opcional, para el mapa (-90 a 90)"}
            longitud: {type: number, example: -79.6539, description: "Opcional, para el mapa (-180 a 180)"}
    responses:
      201: {description: Ciudad creada}
      400: {description: Nombre inválido}
      403: {description: Solo el administrador}
      409: {description: La ciudad ya existe}
    """
    requerir_admin()
    data = leer_json(request)
    nombre = nombre_catalogo(data, "nombre", "El nombre de la ciudad").title()
    coordenadas = {}
    for campo, limite in (("latitud", 90), ("longitud", 180)):
        valor = data.get(campo)
        if valor in (None, ""):
            coordenadas[campo] = None
            continue
        try:
            coordenadas[campo] = round(float(valor), 5)
            if not -limite <= coordenadas[campo] <= limite:
                raise ValueError
        except (TypeError, ValueError):
            raise ErrorApi("Datos inválidos", 400, {campo: f"La {campo} debe ser un número entre -{limite} y {limite}"})
    if (coordenadas["latitud"] is None) != (coordenadas["longitud"] is None):
        raise ErrorApi("Datos inválidos", 400, {"longitud": "Escriba la latitud y la longitud, o ninguna"})
    repetido = f"La ciudad {nombre} ya existe"
    if ya_existe("ciudades", nombre):
        raise ErrorApi(repetido, 409, {"nombre": repetido})
    insertar_unico("INSERT INTO vuelos.ciudades (nombre, latitud, longitud) VALUES (:n, :latitud, :longitud)",
                   {"n": nombre, **coordenadas}, repetido, "nombre")
    return jsonify({"mensaje": f"Ciudad {nombre} creada", "ciudad": nombre}), 201


@app.post("/api/vuelos/aerolineas")
def crear_aerolinea():
    """[Administrador] Registrar una aerolínea con su código de 2 caracteres (prefijo de sus vuelos)
    ---
    tags: [Catálogos]
    security: [{Bearer: []}]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [nombre, codigo]
          properties:
            nombre: {type: string, example: Aeroregional}
            codigo: {type: string, example: AR}
    responses:
      201: {description: Aerolínea creada}
      400: {description: Datos inválidos}
      403: {description: Solo el administrador}
      409: {description: El nombre o el código ya existen}
    """
    requerir_admin()
    data = leer_json(request)
    nombre = nombre_catalogo(data, "nombre", "El nombre de la aerolínea", letras_solo=False)
    codigo = str(data.get("codigo") or "").strip().upper()
    if len(codigo) != 2 or not codigo.isalnum():
        raise ErrorApi("Datos inválidos", 400, {"codigo": "El código debe tener 2 letras o números (ej. LA)"})
    if ya_existe("aerolineas", nombre):
        raise ErrorApi(f"La aerolínea {nombre} ya existe", 409, {"nombre": f"La aerolínea {nombre} ya existe"})
    insertar_unico("INSERT INTO vuelos.aerolineas (nombre, codigo) VALUES (:n, :c)", {"n": nombre, "c": codigo},
                   f"El código {codigo} ya lo usa otra aerolínea", "codigo")
    return jsonify({"mensaje": f"Aerolínea {nombre} ({codigo}) creada",
                    "aerolinea": {"nombre": nombre, "codigo": codigo}}), 201


@app.post("/api/vuelos/aviones")
def crear_avion():
    """[Administrador] Registrar un tipo de avión con su cabina
    ---
    tags: [Catálogos]
    security: [{Bearer: []}]
    description: >
      Cada clase indica cuántas filas tiene y su configuración: asientos por bloque separados
      por pasillos ("3-3", "2-4-2"). Las filas se numeran seguidas desde la parte delantera
      (First, Business, Premium, Economy) y las letras van de la A en adelante (sin la I).
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [nombre, clases]
          properties:
            nombre: {type: string, example: Airbus A321neo}
            clases:
              type: array
              items:
                type: object
                properties:
                  clase: {type: string, enum: [FIRST, BUSINESS, PREMIUM, ECONOMY]}
                  filas: {type: integer, example: 25}
                  configuracion: {type: string, example: "3-3"}
    responses:
      201: {description: Avión creado; devuelve el resumen de su cabina}
      400: {description: Datos inválidos}
      403: {description: Solo el administrador}
      409: {description: El avión ya existe}
    """
    requerir_admin()
    data = leer_json(request)
    nombre = nombre_catalogo(data, "nombre", "El nombre del avión", letras_solo=False)
    clases, errores = construir_clases(data.get("clases"))
    if errores:
        raise ErrorApi("Cabina inválida", 400, errores)
    cab = crear_cabina(nombre, clases)
    repetido = f"El avión {nombre} ya existe"
    if ya_existe("aviones", nombre):
        raise ErrorApi(repetido, 409, {"nombre": repetido})
    insertar_unico("INSERT INTO vuelos.aviones (nombre, clases, total_asientos) VALUES (:n, CAST(:c AS jsonb), :t)",
                   {"n": nombre, "c": json.dumps(clases), "t": cab.total}, repetido, "nombre")
    cargar_cabinas()
    return jsonify({"mensaje": f"Avión {nombre} creado con {cab.total} asientos", "avion": cab.resumen()}), 201


# ---------- Creación de vuelos (administrador) ----------

def texto_obligatorio(data, campo, nombre, maximo=60):
    valor = " ".join(str(data.get(campo) or "").split())
    if len(valor) < 2:
        return None, f"{nombre} es obligatorio"
    if len(valor) > maximo:
        return None, f"{nombre} admite máximo {maximo} caracteres"
    return valor, None


def leer_fecha_hora(data, campo, nombre):
    try:
        return datetime.fromisoformat(str(data.get(campo) or "")).replace(second=0, microsecond=0, tzinfo=None), None
    except ValueError:
        return None, f"{nombre} es obligatoria (formato YYYY-MM-DDTHH:MM)"


@app.post("/api/vuelos")
def crear_vuelo():
    """[Administrador] Crear un vuelo con ciudades, aerolínea y avión registrados
    ---
    tags: [Vuelos]
    security: [{Bearer: []}]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [origen, destino, aerolinea, avion, fecha_salida, fecha_llegada, precio]
          properties:
            origen: {type: string, example: Quito}
            destino: {type: string, example: Cuenca}
            aerolinea: {type: string, example: LATAM}
            avion: {type: string, example: Airbus A320}
            fecha_salida: {type: string, example: "2026-12-01T08:30"}
            fecha_llegada: {type: string, example: "2026-12-01T09:20"}
            precio: {type: number, example: 85.5, description: Precio base (Economy)}
    responses:
      201: {description: Vuelo creado con la cabina del avión elegido}
      400: {description: Datos inválidos (detalle por campo)}
      401: {description: Token inválido o ausente}
      403: {description: Solo el administrador}
    """
    requerir_admin()
    data = leer_json(request)
    with engine.connect() as con:
        ciudades = {c.casefold(): c for c in catalogo_ciudades(con)}
        aerolineas = {a["nombre"].casefold(): a for a in catalogo_aerolineas(con)}
    aviones = cargar_cabinas()
    errores = {}
    origen, errores["origen"] = texto_obligatorio(data, "origen", "El origen")
    destino, errores["destino"] = texto_obligatorio(data, "destino", "El destino")
    aerolinea, errores["aerolinea"] = texto_obligatorio(data, "aerolinea", "La aerolínea")
    salida, errores["fecha_salida"] = leer_fecha_hora(data, "fecha_salida", "La fecha de salida")
    llegada, errores["fecha_llegada"] = leer_fecha_hora(data, "fecha_llegada", "La fecha de llegada")
    if origen and origen.casefold() not in ciudades:
        errores["origen"] = f"La ciudad {origen} no está registrada"
    if destino and destino.casefold() not in ciudades:
        errores["destino"] = f"La ciudad {destino} no está registrada"
    if aerolinea and aerolinea.casefold() not in aerolineas:
        errores["aerolinea"] = f"La aerolínea {aerolinea} no está registrada"
    avion = data.get("avion")
    if avion not in aviones:
        errores["avion"] = "Elija un avión registrado"
    try:
        precio = round(float(data.get("precio")), 2)
        if not 1 <= precio <= 10000:
            errores["precio"] = "El precio debe estar entre 1 y 10000"
    except (TypeError, ValueError):
        errores["precio"] = "El precio es obligatorio y debe ser un número"
    if origen and destino and origen.casefold() == destino.casefold():
        errores["destino"] = "El destino debe ser distinto del origen"
    if salida and salida <= config.ahora():
        errores["fecha_salida"] = "La salida debe ser una fecha y hora futura"
    if salida and llegada and not timedelta(minutes=20) <= llegada - salida <= timedelta(hours=20):
        errores["fecha_llegada"] = "La llegada debe ser entre 20 minutos y 20 horas después de la salida"
    errores = {k: v for k, v in errores.items() if v}
    if errores:
        raise ErrorApi("Datos del vuelo inválidos", 400, errores)

    cab = aviones[avion]
    linea = aerolineas[aerolinea.casefold()]
    with engine.begin() as con:
        vuelo_id = con.execute(text("""
            INSERT INTO vuelos.vuelos (codigo, aerolinea, avion, origen, destino, fecha_salida, fecha_llegada,
                                       precio, asientos_totales, asientos_disponibles)
            VALUES (:codigo, :aerolinea, :avion, :origen, :destino, :salida, :llegada, :precio, :total, :total)
            RETURNING id
        """), {"codigo": f"TMP-{uuid.uuid4().hex[:12]}", "aerolinea": linea["nombre"], "avion": avion,
               "origen": ciudades[origen.casefold()], "destino": ciudades[destino.casefold()],
               "salida": salida, "llegada": llegada, "precio": precio, "total": cab.total}).scalar()
        # Código definitivo: código de la aerolínea + id (único y fácil de leer, p. ej. LA0412)
        con.execute(text("UPDATE vuelos.vuelos SET codigo = :c WHERE id = :id"),
                    {"c": f"{linea['codigo']}{vuelo_id:04d}", "id": vuelo_id})
        fila = buscar_vuelo(con, vuelo_id)
    return jsonify({"mensaje": f"Vuelo {fila.codigo} creado con {cab.total} asientos ({cab.avion})",
                    "vuelo": vuelo_a_dict(fila), "cabina": cab.resumen()}), 201


@app.get("/api/vuelos/<int:vuelo_id>")
def obtener_vuelo(vuelo_id):
    """Consultar un vuelo por id
    ---
    tags: [Vuelos]
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
    responses:
      200: {description: Datos del vuelo}
      404: {description: Vuelo no encontrado}
    """
    with engine.connect() as con:
        return jsonify(vuelo_a_dict(buscar_vuelo(con, vuelo_id)))


# ---------- Mapa de asientos ----------

@app.get("/api/vuelos/<int:vuelo_id>/asientos")
def mapa_asientos(vuelo_id):
    """Mapa de asientos del vuelo por clase
    ---
    tags: [Asientos]
    security: [{Bearer: []}]
    description: >
      Estados: DISPONIBLE, OCUPADO, BLOQUEADO (no disponible o retenido por otro usuario),
      SELECCIONADO (retenido por el usuario del token) y RESERVADO (ocupado por una reserva del usuario).
      El token es opcional; sin token no se marcan los asientos propios.
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
    responses:
      200: {description: Distribución de la cabina y estado de cada asiento}
      404: {description: Vuelo no encontrado}
    """
    usuario = usuario_opcional()
    liberar_vencidas(vuelo_id)
    with engine.connect() as con:
        vuelo = buscar_vuelo(con, vuelo_id)
        filas = con.execute(text(f"""
            SELECT asiento, estado, usuario_id, reserva_id, expira_en FROM vuelos.asientos
            WHERE vuelo_id = :id AND {ASIENTO_ACTIVO}
        """), {"id": vuelo_id}).all()
        ahora = con.execute(text("SELECT LOCALTIMESTAMP")).scalar()

    cab = cabina(vuelo.avion)
    estados, mis_retenciones, mis_reservados = {}, [], {}
    for f in filas:
        propio = usuario is not None and f.usuario_id == usuario["id"]
        if f.estado == "RETENIDO":
            if propio:
                estados[f.asiento] = "SELECCIONADO"
                mis_retenciones.append({"asiento": f.asiento,
                                        "segundos_restantes": max(0, int((f.expira_en - ahora).total_seconds()))})
            else:
                estados[f.asiento] = "BLOQUEADO"
        elif f.estado == "OCUPADO" and propio and f.reserva_id:
            estados[f.asiento] = "RESERVADO"
            mis_reservados[f.asiento] = f.reserva_id
        else:
            estados[f.asiento] = f.estado

    clases = []
    for c in cab.clases:
        asientos_clase = [a for a, clase in cab.asientos.items() if clase == c["clase"]]
        conteo = lambda estado: sum(1 for a in asientos_clase if estados.get(a) == estado)  # noqa: E731
        clases.append({
            "clase": c["clase"], "nombre": c["nombre"], "filas": c["filas"], "grupos": c["grupos"],
            "precio": round(float(vuelo.precio) * c["factor"], 2),
            "resumen": {"total": len(asientos_clase),
                        "ocupados": conteo("OCUPADO") + conteo("RESERVADO"),
                        "bloqueados": conteo("BLOQUEADO"),
                        "disponibles": sum(1 for a in asientos_clase if a not in estados)},
        })

    return jsonify({
        "vuelo": vuelo_a_dict(vuelo),
        "avion": cab.avion,
        "retencion_minutos": config.RETENCION_MINUTOS,
        "clases": clases,
        "estados": estados,
        "mis_retenciones": mis_retenciones,
        "mis_reservados": mis_reservados,
    })


@app.post("/api/vuelos/<int:vuelo_id>/asientos/<asiento>/retener")
def retener_asiento(vuelo_id, asiento):
    """Seleccionar un asiento (retención temporal mientras se completa la reserva)
    ---
    tags: [Asientos]
    security: [{Bearer: []}]
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
      - {in: path, name: asiento, type: string, required: true, example: 31A}
    responses:
      200: {description: Asiento retenido para el usuario}
      400: {description: El vuelo ya despegó o se alcanzó el máximo de asientos}
      401: {description: Token inválido o ausente}
      403: {description: El administrador no puede seleccionar asientos}
      404: {description: Vuelo o asiento no existe}
      409: {description: El asiento ya fue tomado por otro usuario}
    """
    usuario = no_admin(requerir_token(), "seleccionar asientos: solo puede ver los vuelos y los asientos")
    try:
        with engine.begin() as con:
            vuelo = buscar_vuelo(con, vuelo_id, bloquear=True)
            cab = cabina(vuelo.avion)
            asiento = validar_asiento(asiento, cab)
            if vuelo.fecha_salida <= config.ahora():
                raise ErrorApi("El vuelo ya despegó", 400)
            # Las retenciones vencidas se liberan antes de intentar tomar el asiento
            con.execute(text("""
                DELETE FROM vuelos.asientos
                WHERE vuelo_id = :v AND asiento = :a AND estado = 'RETENIDO' AND expira_en <= LOCALTIMESTAMP
            """), {"v": vuelo_id, "a": asiento})
            # Si ya es mío, solo se renueva el tiempo
            renovado = con.execute(text("""
                UPDATE vuelos.asientos SET expira_en = LOCALTIMESTAMP + make_interval(mins => :min)
                WHERE vuelo_id = :v AND asiento = :a AND estado = 'RETENIDO' AND usuario_id = :u
            """), {"v": vuelo_id, "a": asiento, "u": usuario["id"], "min": config.RETENCION_MINUTOS}).rowcount
            if not renovado:
                mias = con.execute(text(f"""
                    SELECT COUNT(*) FROM vuelos.asientos
                    WHERE vuelo_id = :v AND usuario_id = :u AND estado = 'RETENIDO' AND {ASIENTO_ACTIVO}
                """), {"v": vuelo_id, "u": usuario["id"]}).scalar()
                if mias >= MAX_ASIENTOS_POR_USUARIO:
                    raise ErrorApi(f"Solo puede seleccionar hasta {MAX_ASIENTOS_POR_USUARIO} asientos", 400)
                con.execute(text("""
                    INSERT INTO vuelos.asientos (vuelo_id, asiento, clase, estado, usuario_id, expira_en)
                    VALUES (:v, :a, :c, 'RETENIDO', :u, LOCALTIMESTAMP + make_interval(mins => :min))
                """), {"v": vuelo_id, "a": asiento, "c": cab.asientos[asiento], "u": usuario["id"],
                       "min": config.RETENCION_MINUTOS})
    except IntegrityError:
        raise ErrorApi(f"El asiento {asiento} ya fue tomado por otro usuario", 409, {"asiento": asiento})

    return jsonify({"mensaje": f"Asiento {asiento} seleccionado", "asiento": asiento, "clase": cab.asientos[asiento],
                    "precio": cab.precio(vuelo.precio, asiento),
                    "segundos_restantes": config.RETENCION_MINUTOS * 60})


@app.delete("/api/vuelos/<int:vuelo_id>/asientos/<asiento>/retener")
def soltar_asiento(vuelo_id, asiento):
    """Quitar la selección de un asiento retenido por el usuario
    ---
    tags: [Asientos]
    security: [{Bearer: []}]
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
      - {in: path, name: asiento, type: string, required: true}
    responses:
      200: {description: Asiento liberado}
      401: {description: Token inválido o ausente}
      404: {description: El usuario no tenía ese asiento seleccionado}
    """
    usuario = requerir_token()
    with engine.begin() as con:
        asiento = validar_asiento(asiento, cabina(buscar_vuelo(con, vuelo_id, bloquear=True).avion))
        borrados = con.execute(text("""
            DELETE FROM vuelos.asientos
            WHERE vuelo_id = :v AND asiento = :a AND estado = 'RETENIDO' AND usuario_id = :u
        """), {"v": vuelo_id, "a": asiento, "u": usuario["id"]}).rowcount
    if not borrados:
        raise ErrorApi("No tenía ese asiento seleccionado", 404)
    return jsonify({"mensaje": f"Asiento {asiento} liberado"})


# ---------- Endpoints internos (los usa el servicio de Reservas) ----------

@app.post("/api/vuelos/<int:vuelo_id>/asientos/confirmar")
def confirmar_asientos(vuelo_id):
    """[Interno] Marcar asientos como OCUPADOS para una reserva (todo o nada)
    ---
    tags: [Interno]
    security: [{ServiceKey: []}]
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [usuario_id, reserva_id, asientos]
          properties:
            usuario_id: {type: integer}
            reserva_id: {type: integer}
            asientos: {type: array, items: {type: string}, example: [31A, 31C]}
    responses:
      200: {description: Asientos ocupados, devuelve clase y precio de cada uno}
      403: {description: Falta la clave de servicio}
      404: {description: Vuelo o asiento no existe}
      409: {description: Algún asiento ya no está disponible}
    """
    requerir_clave_servicio()
    data = leer_json(request)
    usuario_id, reserva_id = data.get("usuario_id"), data.get("reserva_id")
    if not isinstance(usuario_id, int) or not isinstance(reserva_id, int):
        raise ErrorApi("usuario_id y reserva_id son obligatorios", 400)

    parametros = {"v": vuelo_id, "u": usuario_id, "r": reserva_id}
    try:
        with engine.begin() as con:
            vuelo = buscar_vuelo(con, vuelo_id, bloquear=True)
            cab = cabina(vuelo.avion)
            asientos = validar_lista_asientos(data, cab)
            # FOR UPDATE bloquea las filas consultadas hasta terminar la transacción;
            # si un asiento libre lo toma otro usuario a la vez, la clave primaria rechaza el INSERT
            ocupados = con.execute(text(f"""
                SELECT asiento FROM vuelos.asientos
                WHERE vuelo_id = :v AND asiento IN :asientos AND {ASIENTO_ACTIVO}
                  AND NOT (estado = 'RETENIDO' AND usuario_id = :u)
                FOR UPDATE
            """).bindparams(bindparam("asientos", expanding=True)), {**parametros, "asientos": asientos}).scalars().all()
            if ocupados:
                raise ErrorApi("Algunos asientos ya no están disponibles", 409, {"asientos_no_disponibles": ocupados})
            for asiento in asientos:
                p = {**parametros, "a": asiento}
                con.execute(text("""
                    DELETE FROM vuelos.asientos
                    WHERE vuelo_id = :v AND asiento = :a AND estado = 'RETENIDO' AND expira_en <= LOCALTIMESTAMP
                """), p)
                tomado = con.execute(text("""
                    UPDATE vuelos.asientos SET estado = 'OCUPADO', reserva_id = :r, expira_en = NULL, fecha = LOCALTIMESTAMP
                    WHERE vuelo_id = :v AND asiento = :a AND estado = 'RETENIDO' AND usuario_id = :u
                """), p).rowcount
                if not tomado:
                    con.execute(text("""
                        INSERT INTO vuelos.asientos (vuelo_id, asiento, clase, estado, usuario_id, reserva_id)
                        VALUES (:v, :a, :c, 'OCUPADO', :u, :r)
                    """), {**p, "c": cab.asientos[asiento]})
    except IntegrityError:
        raise ErrorApi("Otro usuario tomó uno de los asientos al mismo tiempo", 409)

    return jsonify({"mensaje": "Asientos confirmados", "vuelo": vuelo_a_dict(vuelo), "asientos": [
        {"asiento": a, "clase": cab.asientos[a], "precio": cab.precio(vuelo.precio, a)} for a in asientos]})


@app.post("/api/vuelos/<int:vuelo_id>/asientos/liberar")
def liberar_asientos(vuelo_id):
    """[Interno] Liberar los asientos de una reserva (todos o una lista)
    ---
    tags: [Interno]
    security: [{ServiceKey: []}]
    parameters:
      - {in: path, name: vuelo_id, type: integer, required: true}
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [reserva_id]
          properties:
            reserva_id: {type: integer}
            asientos: {type: array, items: {type: string}}
    responses:
      200: {description: Asientos liberados}
      403: {description: Falta la clave de servicio}
    """
    requerir_clave_servicio()
    data = leer_json(request)
    if not isinstance(data.get("reserva_id"), int):
        raise ErrorApi("reserva_id es obligatorio", 400)
    sql = "DELETE FROM vuelos.asientos WHERE vuelo_id = :v AND reserva_id = :r AND estado = 'OCUPADO'"
    parametros = {"v": vuelo_id, "r": data["reserva_id"]}
    sentencia = text(sql)
    with engine.begin() as con:
        vuelo = buscar_vuelo(con, vuelo_id, bloquear=True)
        if data.get("asientos"):
            parametros["asientos"] = validar_lista_asientos(data, cabina(vuelo.avion))
            sentencia = text(sql + " AND asiento IN :asientos").bindparams(bindparam("asientos", expanding=True))
        liberados = con.execute(sentencia, parametros).rowcount
    return jsonify({"mensaje": "Asientos liberados", "liberados": liberados})


if __name__ == "__main__":
    app.run(host=config.BIND_HOST, port=config.VUELOS_PORT, threaded=True)
