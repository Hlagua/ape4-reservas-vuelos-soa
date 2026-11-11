"""Pruebas del servicio de Vuelos (consulta y mapa de asientos)."""
from datetime import date, datetime, timedelta

import pytest
import requests
from sqlalchemy import text

from tests.conftest import solo_local

from common import config
from common.db import engine

VUELOS_DIRECTO = f"http://127.0.0.1:{config.VUELOS_PORT}"


def test_buscar_todos(base):
    resp = requests.get(f"{base}/api/vuelos")
    assert resp.status_code == 200
    assert resp.json()["total"] > 0


def test_buscar_con_filtros(base):
    fecha = (date.today() + timedelta(days=3)).isoformat()
    resp = requests.get(f"{base}/api/vuelos", params={"origen": "Quito", "destino": "Guayaquil", "fecha": fecha})
    vuelos = resp.json()["vuelos"]
    assert resp.status_code == 200 and vuelos
    assert all(v["origen"] == "Quito" and v["destino"] == "Guayaquil" for v in vuelos)
    assert all(v["fecha_salida"].startswith(fecha) for v in vuelos)


def test_buscar_por_pasajeros(base):
    resp = requests.get(f"{base}/api/vuelos", params={"origen": "Quito", "pasajeros": 5})
    assert resp.status_code == 200
    assert resp.json()["vuelos"] and all(v["asientos_disponibles"] >= 5 for v in resp.json()["vuelos"])


def test_buscar_fecha_invalida(base):
    assert requests.get(f"{base}/api/vuelos", params={"fecha": "27-10-2026"}).status_code == 400


def test_buscar_pasajeros_invalido(base):
    assert requests.get(f"{base}/api/vuelos", params={"pasajeros": "abc"}).status_code == 400
    assert requests.get(f"{base}/api/vuelos", params={"pasajeros": "6"}).status_code == 400


def test_listar_ciudades(base):
    datos = requests.get(f"{base}/api/vuelos/ciudades").json()
    assert "Quito" in datos["origenes"] and "Guayaquil" in datos["destinos"]


def test_vuelo_inexistente(base):
    assert requests.get(f"{base}/api/vuelos/999999").status_code == 404


def test_mapa_de_asientos(base, vuelo_prueba):
    mapa = requests.get(f"{base}/api/vuelos/{vuelo_prueba}/asientos").json()
    assert [c["clase"] for c in mapa["clases"]] == ["FIRST", "BUSINESS", "PREMIUM", "ECONOMY"]
    assert sum(c["resumen"]["total"] for c in mapa["clases"]) == mapa["vuelo"]["asientos_totales"]
    assert all(c["resumen"]["disponibles"] == c["resumen"]["total"] for c in mapa["clases"])
    precios = [c["precio"] for c in mapa["clases"]]
    assert precios == sorted(precios, reverse=True)  # First es la clase más cara


@solo_local
def test_endpoint_interno_sin_clave(vuelo_prueba):
    resp = requests.post(f"{VUELOS_DIRECTO}/api/vuelos/{vuelo_prueba}/asientos/confirmar",
                         json={"usuario_id": 1, "reserva_id": 1, "asientos": ["31A"]})
    assert resp.status_code == 403


def test_gateway_no_reenvia_clave_interna(base, vuelo_prueba):
    resp = requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/confirmar",
                         json={"usuario_id": 1, "reserva_id": 1, "asientos": ["31A"]},
                         headers={"X-Service-Key": config.SERVICE_KEY})
    assert resp.status_code == 403


# ---------- Tipos de avión y creación de vuelos (administrador) ----------

def test_aviones_con_distinto_numero_de_asientos(base):
    aviones = {a["avion"]: a for a in requests.get(f"{base}/api/vuelos/aviones").json()["aviones"]}
    assert {"Airbus A340-600", "Airbus A320", "ATR 72-600"} <= set(aviones)
    assert aviones["Airbus A340-600"]["total_asientos"] == 226
    assert aviones["Airbus A320"]["total_asientos"] == 162
    assert aviones["ATR 72-600"]["total_asientos"] == 72
    assert len({a["total_asientos"] for a in aviones.values()}) == len(aviones)


def datos_vuelo(**cambios):
    salida = datetime.now().replace(second=0, microsecond=0) + timedelta(days=20)
    return {"origen": "Ambato", "destino": "Loja", "aerolinea": "UTA Air", "avion": "Airbus A320",
            "fecha_salida": salida.isoformat(timespec="minutes"),
            "fecha_llegada": (salida + timedelta(minutes=55)).isoformat(timespec="minutes"),
            "precio": 70, **cambios}


@pytest.fixture
def admin():
    if not config.ADMIN_KEY:
        pytest.skip("Sin ADMIN_KEY configurada")
    return {"X-Admin-Key": config.ADMIN_KEY}


def borrar_vuelo(vuelo_id):
    with engine.begin() as con:
        con.execute(text("SELECT id FROM vuelos.vuelos WHERE id = :v FOR UPDATE"), {"v": vuelo_id})
        con.execute(text("DELETE FROM reservas.reservas WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("DELETE FROM vuelos.asientos WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("DELETE FROM vuelos.vuelos WHERE id = :v"), {"v": vuelo_id})


@solo_local
def test_admin_crea_vuelo_con_la_cabina_del_avion(base, admin, usuario):
    resp = requests.post(f"{base}/api/admin/vuelos", json=datos_vuelo(), headers=admin)
    assert resp.status_code == 201, resp.text
    vuelo = resp.json()["vuelo"]
    try:
        assert vuelo["codigo"].startswith("UT") and vuelo["avion"] == "Airbus A320"
        assert vuelo["asientos_totales"] == 162 and vuelo["origen"] == "Ambato"
        # Aparece en la búsqueda con su capacidad
        encontrados = requests.get(f"{base}/api/vuelos", params={"origen": "Ambato", "destino": "Loja"}).json()
        assert any(v["id"] == vuelo["id"] and v["asientos_disponibles"] == 162 for v in encontrados["vuelos"])
        # El mapa respeta la estructura del A320: Business 1-3 (2-2) y Economy 6-30 (3-3)
        mapa = requests.get(f"{base}/api/vuelos/{vuelo['id']}/asientos").json()
        assert mapa["avion"] == "Airbus A320"
        clases = {c["clase"]: c for c in mapa["clases"]}
        assert set(clases) == {"BUSINESS", "ECONOMY"}
        assert clases["ECONOMY"]["grupos"] == [["A", "B", "C"], ["D", "E", "F"]]
        assert clases["BUSINESS"]["precio"] == 210.0
        # Un asiento que no existe en este avión (31A sí existe en el A340) se rechaza
        h = usuario["headers"]
        assert requests.post(f"{base}/api/vuelos/{vuelo['id']}/asientos/31A/retener", headers=h).status_code == 404
        resp = requests.post(f"{base}/api/vuelos/{vuelo['id']}/asientos/6B/retener", headers=h)
        assert resp.status_code == 200 and resp.json()["precio"] == 70.0
        assert requests.delete(f"{base}/api/vuelos/{vuelo['id']}/asientos/6B/retener", headers=h).status_code == 200
    finally:
        borrar_vuelo(vuelo["id"])


def test_crear_vuelo_valida_los_datos(base, admin):
    pasado = (datetime.now() - timedelta(days=1)).isoformat(timespec="minutes")
    resp = requests.post(f"{base}/api/admin/vuelos", headers=admin, json=datos_vuelo(
        destino="ambato", avion="Concorde", fecha_salida=pasado, precio=0, aerolinea=""))
    assert resp.status_code == 400
    assert {"destino", "avion", "fecha_salida", "precio", "aerolinea"} <= set(resp.json()["detalle"])
    resp = requests.post(f"{base}/api/admin/vuelos", headers=admin, json=datos_vuelo(
        fecha_llegada=datos_vuelo()["fecha_salida"]))
    assert resp.status_code == 400 and "fecha_llegada" in resp.json()["detalle"]


def test_crear_vuelo_solo_administrador(base, usuario):
    assert requests.post(f"{base}/api/admin/vuelos", json=datos_vuelo()).status_code == 403
    assert requests.post(f"{base}/api/admin/vuelos", json=datos_vuelo(),
                         headers={"X-Admin-Key": "clave-incorrecta"}).status_code == 403
    # Directo por la ruta pública del servicio (sin clave de servicio) tampoco se puede
    assert requests.post(f"{base}/api/vuelos", json=datos_vuelo(), headers=usuario["headers"]).status_code == 403
