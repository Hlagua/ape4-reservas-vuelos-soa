"""Pruebas del servicio de Vuelos (consulta y mapa de asientos)."""
from datetime import date, timedelta

import requests

from common import config

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


def test_endpoint_interno_sin_clave(vuelo_prueba):
    resp = requests.post(f"{VUELOS_DIRECTO}/api/vuelos/{vuelo_prueba}/asientos/confirmar",
                         json={"usuario_id": 1, "reserva_id": 1, "asientos": ["31A"]})
    assert resp.status_code == 403


def test_gateway_no_reenvia_clave_interna(base, vuelo_prueba):
    resp = requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/confirmar",
                         json={"usuario_id": 1, "reserva_id": 1, "asientos": ["31A"]},
                         headers={"X-Service-Key": config.SERVICE_KEY})
    assert resp.status_code == 403
