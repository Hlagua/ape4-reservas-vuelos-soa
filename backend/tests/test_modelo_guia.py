"""Pruebas del modelo de datos y del ejemplo de petición de la guía APE 4."""
from concurrent.futures import ThreadPoolExecutor

import requests
from sqlalchemy import text

from common.db import engine
from tests.conftest import crear_usuario, pasajero


def disponibles_en_bd(vuelo_id):
    with engine.connect() as con:
        return con.execute(text("SELECT asientos_disponibles FROM vuelos.vuelos WHERE id = :v"),
                           {"v": vuelo_id}).scalar()


# ---------- Ejemplo 5 de la guía: {usuario_id, vuelo_id, cantidad} ----------

def test_reserva_formato_guia(base, usuario, vuelo_prueba):
    resp = requests.post(f"{base}/api/reservas", headers=usuario["headers"],
                         json={"usuario_id": usuario["id"], "vuelo_id": vuelo_prueba, "cantidad": 2})
    assert resp.status_code == 201, resp.text
    cuerpo = resp.json()
    assert cuerpo["mensaje"] == "Reserva creada"
    assert cuerpo["estado"] == "confirmada"
    assert cuerpo["cantidad"] == 2 and len(cuerpo["asientos"]) == 2
    assert cuerpo["total"] == 100.00  # 2 asientos Economy del vuelo de prueba a $50

    # Se puede consultar y facturar como cualquier reserva (cliente: consumidor final)
    detalle = requests.get(f"{base}/api/reservas/{cuerpo['reserva_id']}", headers=usuario["headers"]).json()
    assert detalle["reserva"]["cantidad_asientos"] == 2
    factura = requests.get(f"{base}/api/facturas/reserva/{cuerpo['reserva_id']}", headers=usuario["headers"])
    assert "<CedulaRuc>9999999999999</CedulaRuc>" in factura.text


def test_reserva_formato_guia_validaciones(base, usuario, otro_usuario, vuelo_prueba):
    url = f"{base}/api/reservas"
    assert requests.post(url, json={"vuelo_id": vuelo_prueba, "cantidad": 1}).status_code == 401
    otro = requests.post(url, headers=usuario["headers"],
                         json={"usuario_id": otro_usuario["id"], "vuelo_id": vuelo_prueba, "cantidad": 1})
    assert otro.status_code == 403
    for cantidad in (0, 6, "2", 1.5):
        resp = requests.post(url, headers=usuario["headers"], json={"vuelo_id": vuelo_prueba, "cantidad": cantidad})
        assert resp.status_code == 400, cantidad
    assert requests.post(url, headers=usuario["headers"], json={"vuelo_id": 999999, "cantidad": 1}).status_code == 404


def test_reservas_simultaneas_por_cantidad_no_repiten_asientos(base, vuelo_prueba):
    """10 clientes piden 3 asientos a la vez: ningún asiento se asigna dos veces."""
    usuarios = [crear_usuario() for _ in range(10)]

    def reservar(u):
        return requests.post(f"{base}/api/reservas", headers=u["headers"],
                             json={"vuelo_id": vuelo_prueba, "cantidad": 3})

    with ThreadPoolExecutor(max_workers=10) as pool:
        respuestas = list(pool.map(reservar, usuarios))
    asientos = [a for r in respuestas if r.status_code == 201 for a in r.json()["asientos"]]
    assert all(r.status_code in (201, 409) for r in respuestas)
    assert len(asientos) == len(set(asientos)) >= 3
    assert disponibles_en_bd(vuelo_prueba) == 226 - len(asientos)


# ---------- Modelo de datos ----------

def test_asientos_disponibles_se_mantiene_en_la_tabla(base, usuario, vuelo_prueba):
    assert disponibles_en_bd(vuelo_prueba) == 226
    requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/31A/retener", headers=usuario["headers"])
    assert disponibles_en_bd(vuelo_prueba) == 225
    reserva = requests.post(f"{base}/api/reservas", headers=usuario["headers"],
                            json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("31A"), pasajero("31C")]}).json()
    assert disponibles_en_bd(vuelo_prueba) == 224
    requests.delete(f"{base}/api/reservas/{reserva['reserva']['id']}", headers=usuario["headers"])
    assert disponibles_en_bd(vuelo_prueba) == 226


def test_columnas_y_relaciones_de_la_guia():
    with engine.connect() as con:
        columnas = {(f.table_schema, f.table_name, f.column_name) for f in con.execute(text("""
            SELECT table_schema, table_name, column_name FROM information_schema.columns
            WHERE table_schema IN ('usuarios', 'autenticacion', 'vuelos', 'reservas')"""))}
        relaciones = {(f.tabla, f.referencia) for f in con.execute(text("""
            SELECT conrelid::regclass::text AS tabla, confrelid::regclass::text AS referencia
            FROM pg_constraint WHERE contype = 'f'"""))}
    esperadas = {
        ("usuarios", "usuarios", "correo"), ("usuarios", "usuarios", "password_hash"),
        ("vuelos", "vuelos", "fecha"), ("vuelos", "vuelos", "hora_salida"), ("vuelos", "vuelos", "hora_llegada"),
        ("vuelos", "vuelos", "asientos_disponibles"), ("reservas", "reservas", "cantidad_asientos"),
        ("autenticacion", "tokens", "expiracion"), ("autenticacion", "tokens", "estado"),
    }
    assert esperadas <= columnas
    assert {("reservas.reservas", "usuarios.usuarios"), ("reservas.reservas", "vuelos.vuelos"),
            ("autenticacion.tokens", "usuarios.usuarios")} <= relaciones
