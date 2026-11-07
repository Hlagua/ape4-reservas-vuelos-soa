"""Crea los esquemas de cada servicio en PostgreSQL (Supabase) y carga datos de ejemplo.

Uso:
    python -m database.init_db          # crea lo que falte
    python -m database.init_db --reset  # borra los esquemas del sistema y los vuelve a crear
"""
import random
import sys
from datetime import datetime, time, timedelta

from sqlalchemy import text
from werkzeug.security import generate_password_hash

from common import config
from common.db import engine
from servicio_vuelos.cabina import ASIENTOS, AVION

# Cada servicio es dueño de su propio esquema (no hay FK entre esquemas).
# "autenticacion" evita chocar con el esquema "auth" que Supabase ya trae.
ESQUEMAS = ["usuarios", "autenticacion", "vuelos", "reservas"]

SCRIPT_TABLAS = [
    *[f"CREATE SCHEMA IF NOT EXISTS {e}" for e in ESQUEMAS],
    """
    CREATE TABLE IF NOT EXISTS usuarios.usuarios (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        nombre VARCHAR(80) NOT NULL,
        email VARCHAR(150) NOT NULL UNIQUE,
        password_hash VARCHAR(255) NOT NULL,
        fecha_registro TIMESTAMP NOT NULL DEFAULT LOCALTIMESTAMP
    )
    """,
    # Tokens JWT emitidos: permiten cerrar sesión (revocar) antes de que expiren
    """
    CREATE TABLE IF NOT EXISTS autenticacion.tokens (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        usuario_id INTEGER NOT NULL,
        jti VARCHAR(36) NOT NULL UNIQUE,
        token_hash CHAR(64) NOT NULL,
        fecha_emision TIMESTAMP NOT NULL DEFAULT LOCALTIMESTAMP,
        expiracion TIMESTAMP NOT NULL,
        estado VARCHAR(10) NOT NULL DEFAULT 'ACTIVO' CHECK (estado IN ('ACTIVO', 'REVOCADO'))
    )
    """,
    "CREATE INDEX IF NOT EXISTS ix_tokens_usuario ON autenticacion.tokens (usuario_id)",
    """
    CREATE TABLE IF NOT EXISTS vuelos.vuelos (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        codigo VARCHAR(20) NOT NULL UNIQUE,
        aerolinea VARCHAR(60) NOT NULL,
        avion VARCHAR(60) NOT NULL,
        origen VARCHAR(60) NOT NULL,
        destino VARCHAR(60) NOT NULL,
        fecha_salida TIMESTAMP NOT NULL,
        fecha_llegada TIMESTAMP NOT NULL,
        precio NUMERIC(10,2) NOT NULL
    )
    """,
    # Un asiento sin fila en esta tabla está DISPONIBLE.
    # La clave primaria (vuelo_id, asiento) garantiza que dos usuarios
    # nunca puedan tener el mismo asiento al mismo tiempo.
    """
    CREATE TABLE IF NOT EXISTS vuelos.asientos (
        vuelo_id INTEGER NOT NULL REFERENCES vuelos.vuelos(id),
        asiento VARCHAR(4) NOT NULL,
        clase VARCHAR(10) NOT NULL,
        estado VARCHAR(10) NOT NULL CHECK (estado IN ('BLOQUEADO', 'RETENIDO', 'OCUPADO')),
        usuario_id INTEGER NULL,
        reserva_id INTEGER NULL,
        expira_en TIMESTAMP NULL,
        fecha TIMESTAMP NOT NULL DEFAULT LOCALTIMESTAMP,
        CONSTRAINT pk_asientos PRIMARY KEY (vuelo_id, asiento)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS reservas.reservas (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        usuario_id INTEGER NOT NULL,
        vuelo_id INTEGER NOT NULL,
        codigo_vuelo VARCHAR(20) NOT NULL,
        pasajeros INTEGER NOT NULL,
        total NUMERIC(10,2) NOT NULL,
        estado VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
        fecha_reserva TIMESTAMP NOT NULL DEFAULT LOCALTIMESTAMP,
        fecha_actualizacion TIMESTAMP NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS reservas.pasajeros (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        reserva_id INTEGER NOT NULL REFERENCES reservas.reservas(id) ON DELETE CASCADE,
        asiento VARCHAR(4) NOT NULL,
        clase VARCHAR(10) NOT NULL,
        nombre VARCHAR(80) NOT NULL,
        tipo_documento VARCHAR(10) NOT NULL,
        documento VARCHAR(15) NOT NULL,
        precio NUMERIC(10,2) NOT NULL
    )
    """,
]

RUTAS = [
    ("Quito", "Guayaquil", 45, 89.90),
    ("Guayaquil", "Quito", 45, 89.90),
    ("Quito", "Cuenca", 50, 79.50),
    ("Cuenca", "Quito", 50, 79.50),
    ("Guayaquil", "Galápagos", 110, 245.00),
    ("Quito", "Bogotá", 85, 210.00),
    ("Quito", "Lima", 140, 260.00),
    ("Guayaquil", "Madrid", 650, 980.00),
]
AEROLINEAS = ["LATAM", "Avianca", "Equair", "Iberia"]
DIAS_A_GENERAR = 30
USUARIO_DEMO = {"nombre": "Usuario Demo", "email": "demo@uta.edu.ec", "password": "demo1234"}


def borrar_esquemas():
    with engine.begin() as con:
        for e in reversed(ESQUEMAS):
            con.execute(text(f"DROP SCHEMA IF EXISTS {e} CASCADE"))
    print("Esquemas del sistema eliminados")


def crear_tablas():
    with engine.begin() as con:
        for sentencia in SCRIPT_TABLAS:
            con.execute(text(sentencia))
    print("Esquemas y tablas listos")


def cargar_vuelos():
    with engine.begin() as con:
        if con.execute(text("SELECT COUNT(*) FROM vuelos.vuelos")).scalar():
            print("Ya existen vuelos, no se cargan datos de ejemplo")
            return
        rnd = random.Random(2026)
        hoy = config.ahora().date()
        vuelos = []
        for dia in range(DIAS_A_GENERAR):
            fecha = hoy + timedelta(days=dia)
            for i, (origen, destino, minutos, precio) in enumerate(RUTAS):
                for hora in (7, 15):
                    salida = datetime.combine(fecha, time(hora, rnd.choice([0, 15, 30, 45])))
                    aerolinea = AEROLINEAS[(i + hora) % len(AEROLINEAS)]
                    vuelos.append({
                        "codigo": f"{aerolinea[:2].upper()}{fecha:%m%d}{i}{hora:02d}",
                        "aerolinea": aerolinea, "origen": origen, "destino": destino,
                        "salida": salida, "llegada": salida + timedelta(minutes=minutos),
                        "precio": round(precio * rnd.uniform(0.85, 1.25), 2),
                    })
        # Vuelo vacío para las pruebas de concurrencia
        salida = datetime.combine(hoy + timedelta(days=1), time(10, 0))
        vuelos.append({"codigo": "UTA-TEST", "aerolinea": "UTA Air", "origen": "Ambato", "destino": "Quito",
                       "salida": salida, "llegada": salida + timedelta(minutes=40), "precio": 50.00})

        ids = con.execute(text("""
            INSERT INTO vuelos.vuelos (codigo, aerolinea, avion, origen, destino, fecha_salida, fecha_llegada, precio)
            SELECT codigo, aerolinea, :avion, origen, destino, salida, llegada, precio
            FROM json_to_recordset(CAST(:filas AS json)) AS f(codigo text, aerolinea text, origen text,
                 destino text, salida timestamp, llegada timestamp, precio numeric)
            RETURNING id, codigo
        """), {"avion": AVION, "filas": _json(vuelos)}).all()
        id_por_codigo = {f.codigo: f.id for f in ids}

        # Asientos ya vendidos por otros canales u ocupados por la aerolínea
        asientos = []
        for v in vuelos:
            if v["codigo"] == "UTA-TEST":
                continue
            ocupacion = rnd.uniform(0.15, 0.55)
            for asiento, clase in ASIENTOS.items():
                azar = rnd.random()
                if azar < ocupacion + 0.08:
                    asientos.append({"vuelo_id": id_por_codigo[v["codigo"]], "asiento": asiento, "clase": clase,
                                     "estado": "OCUPADO" if azar < ocupacion else "BLOQUEADO"})
        con.execute(text("""
            INSERT INTO vuelos.asientos (vuelo_id, asiento, clase, estado)
            SELECT vuelo_id, asiento, clase, estado
            FROM json_to_recordset(CAST(:filas AS json)) AS f(vuelo_id int, asiento text, clase text, estado text)
        """), {"filas": _json(asientos)})
    print(f"{len(vuelos)} vuelos y {len(asientos)} asientos ocupados/bloqueados cargados")


def _json(filas):
    import json
    return json.dumps(filas, default=str, ensure_ascii=False)


def cargar_usuario_demo():
    with engine.begin() as con:
        if con.execute(text("SELECT 1 FROM usuarios.usuarios WHERE email = :e"), {"e": USUARIO_DEMO["email"]}).first():
            return
        con.execute(text("INSERT INTO usuarios.usuarios (nombre, email, password_hash) VALUES (:n, :e, :h)"),
                    {"n": USUARIO_DEMO["nombre"], "e": USUARIO_DEMO["email"],
                     "h": generate_password_hash(USUARIO_DEMO["password"], method="pbkdf2:sha256")})
    print(f"Usuario demo creado: {USUARIO_DEMO['email']} / {USUARIO_DEMO['password']}")


if __name__ == "__main__":
    if "--reset" in sys.argv:
        borrar_esquemas()
    crear_tablas()
    cargar_vuelos()
    cargar_usuario_demo()
