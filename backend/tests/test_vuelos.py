"""Pruebas del servicio de Vuelos (consulta y mapa de asientos)."""
import uuid
from datetime import date, datetime, timedelta

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


# ---------- Administrador: catálogos y creación de vuelos ----------

def nombre_aleatorio(prefijo):
    """Nombre solo con letras (las ciudades no admiten números)."""
    return prefijo + "".join(chr(97 + int(c, 16)) for c in uuid.uuid4().hex[:8])


def datos_vuelo(**cambios):
    salida = datetime.now().replace(second=0, microsecond=0) + timedelta(days=20)
    return {"origen": "Ambato", "destino": "Loja", "aerolinea": "UTA Air", "avion": "Airbus A320",
            "fecha_salida": salida.isoformat(timespec="minutes"),
            "fecha_llegada": (salida + timedelta(minutes=55)).isoformat(timespec="minutes"),
            "precio": 70, **cambios}


def borrar_vuelo(vuelo_id):
    with engine.begin() as con:
        con.execute(text("SELECT id FROM vuelos.vuelos WHERE id = :v FOR UPDATE"), {"v": vuelo_id})
        con.execute(text("DELETE FROM reservas.reservas WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("DELETE FROM vuelos.asientos WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("DELETE FROM vuelos.vuelos WHERE id = :v"), {"v": vuelo_id})


def borrar_catalogo(tabla, nombre):
    with engine.begin() as con:
        con.execute(text(f"DELETE FROM vuelos.{tabla} WHERE nombre = :n"), {"n": nombre})


def test_login_devuelve_el_rol(admin, usuario):
    assert admin["rol"] == "ADMIN"
    assert usuario["rol"] == "CLIENTE"


def test_catalogos_y_aviones_con_distinto_numero_de_asientos(base):
    catalogos = requests.get(f"{base}/api/vuelos/catalogos").json()
    assert {"Quito", "Guayaquil", "Ambato"} <= set(catalogos["ciudades"])
    assert {"nombre": "LATAM", "codigo": "LA"} in catalogos["aerolineas"]
    aviones = {a["avion"]: a for a in catalogos["aviones"]}
    assert aviones["Airbus A340-600"]["total_asientos"] == 226
    assert aviones["Airbus A320"]["total_asientos"] == 162
    assert aviones["ATR 72-600"]["total_asientos"] == 72
    economy = next(c for c in aviones["Airbus A320"]["clases"] if c["clase"] == "ECONOMY")
    assert economy["configuracion"] == "3-3" and economy["filas"] == 25


@solo_local
def test_admin_crea_ciudad_aerolinea_y_avion(base, admin, usuario):
    h = admin["headers"]
    ciudad, linea, avion = nombre_aleatorio("Villa "), nombre_aleatorio("Aero "), nombre_aleatorio("Avion ")
    codigo = uuid.uuid4().hex[:2].upper()
    try:
        assert requests.post(f"{base}/api/vuelos/ciudades", headers=h,
                             json={"nombre": ciudad, "latitud": 95, "longitud": -79}).status_code == 400
        resp = requests.post(f"{base}/api/vuelos/ciudades", headers=h,
                             json={"nombre": ciudad.lower(), "latitud": 0.9592, "longitud": -79.6539})
        assert resp.status_code == 201 and resp.json()["ciudad"] == ciudad.title()
        coordenadas = requests.get(f"{base}/api/vuelos/catalogos").json()["coordenadas"]
        assert coordenadas[ciudad.title()] == [0.9592, -79.6539]
        assert requests.post(f"{base}/api/vuelos/ciudades", headers=h, json={"nombre": ciudad}).status_code == 409
        assert requests.post(f"{base}/api/vuelos/ciudades", headers=h, json={"nombre": "Quito 2"}).status_code == 400

        resp = requests.post(f"{base}/api/vuelos/aerolineas", headers=h, json={"nombre": linea, "codigo": codigo})
        assert resp.status_code in (201, 409), resp.text  # 409 si el código al azar ya existe
        assert requests.post(f"{base}/api/vuelos/aerolineas", headers=h,
                             json={"nombre": linea + "x", "codigo": "LA"}).status_code == 409
        assert requests.post(f"{base}/api/vuelos/aerolineas", headers=h,
                             json={"nombre": linea, "codigo": "ABC"}).status_code == 400

        # Avión: Business 2 filas 2-2 + Economy 10 filas 3-3 = 8 + 60 = 68 asientos
        resp = requests.post(f"{base}/api/vuelos/aviones", headers=h, json={"nombre": avion, "clases": [
            {"clase": "ECONOMY", "filas": 10, "configuracion": "3-3"},
            {"clase": "BUSINESS", "filas": 2, "configuracion": "2-2"},
        ]})
        assert resp.status_code == 201, resp.text
        assert resp.json()["avion"]["total_asientos"] == 68
        resp = requests.post(f"{base}/api/vuelos/aviones", headers=h, json={"nombre": avion + "x", "clases": [
            {"clase": "ECONOMY", "filas": 10, "configuracion": "3-9"}]})
        assert resp.status_code == 400

        # Vuelo con el avión nuevo: Business filas 1-2 (A C / D F... letras A-D) y Economy filas 3-12
        resp = requests.post(f"{base}/api/vuelos", headers=h, json=datos_vuelo(origen=ciudad, avion=avion))
        assert resp.status_code == 201, resp.text
        vuelo = resp.json()["vuelo"]
        try:
            mapa = requests.get(f"{base}/api/vuelos/{vuelo['id']}/asientos").json()
            clases = {c["clase"]: c for c in mapa["clases"]}
            assert clases["BUSINESS"]["filas"] == [1, 2] and clases["BUSINESS"]["grupos"] == [["A", "B"], ["C", "D"]]
            assert clases["ECONOMY"]["filas"][0] == 3 and clases["ECONOMY"]["grupos"][1] == ["D", "E", "F"]
            assert vuelo["asientos_totales"] == 68
        finally:
            borrar_vuelo(vuelo["id"])
    finally:
        borrar_catalogo("ciudades", ciudad.title())
        borrar_catalogo("aerolineas", linea)
        borrar_catalogo("aviones", avion)


@solo_local
def test_admin_crea_vuelo_y_solo_puede_verlo(base, admin, usuario):
    resp = requests.post(f"{base}/api/vuelos", json=datos_vuelo(), headers=admin["headers"])
    assert resp.status_code == 201, resp.text
    vuelo = resp.json()["vuelo"]
    try:
        assert vuelo["codigo"].startswith("UT") and vuelo["avion"] == "Airbus A320"
        assert vuelo["asientos_totales"] == 162 and vuelo["origen"] == "Ambato"
        encontrados = requests.get(f"{base}/api/vuelos", params={"origen": "Ambato", "destino": "Loja"}).json()
        assert any(v["id"] == vuelo["id"] and v["asientos_disponibles"] == 162 for v in encontrados["vuelos"])
        # El mapa respeta la estructura del A320: Business 1-3 (2-2) y Economy 6-30 (3-3)
        mapa = requests.get(f"{base}/api/vuelos/{vuelo['id']}/asientos", headers=admin["headers"]).json()
        assert mapa["avion"] == "Airbus A320"
        clases = {c["clase"]: c for c in mapa["clases"]}
        assert clases["ECONOMY"]["grupos"] == [["A", "B", "C"], ["D", "E", "F"]]
        assert clases["BUSINESS"]["precio"] == 210.0
        # El administrador ve los asientos pero no los compra
        resp = requests.post(f"{base}/api/vuelos/{vuelo['id']}/asientos/6B/retener", headers=admin["headers"])
        assert resp.status_code == 403
        resp = requests.post(f"{base}/api/reservas", headers=admin["headers"], json={"vuelo_id": vuelo["id"], "cantidad": 1})
        assert resp.status_code == 403
        # Un cliente sí; y un asiento que no existe en este avión (31A sí existe en el A340) se rechaza
        h = usuario["headers"]
        assert requests.post(f"{base}/api/vuelos/{vuelo['id']}/asientos/31A/retener", headers=h).status_code == 404
        resp = requests.post(f"{base}/api/vuelos/{vuelo['id']}/asientos/6B/retener", headers=h)
        assert resp.status_code == 200 and resp.json()["precio"] == 70.0
        assert requests.delete(f"{base}/api/vuelos/{vuelo['id']}/asientos/6B/retener", headers=h).status_code == 200
    finally:
        borrar_vuelo(vuelo["id"])


def test_crear_vuelo_valida_los_datos(base, admin):
    pasado = (datetime.now() - timedelta(days=1)).isoformat(timespec="minutes")
    resp = requests.post(f"{base}/api/vuelos", headers=admin["headers"], json=datos_vuelo(
        destino="ambato", avion="Concorde", fecha_salida=pasado, precio=0, aerolinea=""))
    assert resp.status_code == 400
    assert {"destino", "avion", "fecha_salida", "precio", "aerolinea"} <= set(resp.json()["detalle"])
    resp = requests.post(f"{base}/api/vuelos", headers=admin["headers"], json=datos_vuelo(
        origen="Ciudad Inexistente", aerolinea="Aerolinea Inexistente",
        fecha_llegada=datos_vuelo()["fecha_salida"]))
    assert resp.status_code == 400
    assert {"origen", "aerolinea", "fecha_llegada"} <= set(resp.json()["detalle"])


def test_catalogos_y_vuelos_solo_administrador(base, usuario):
    assert requests.post(f"{base}/api/vuelos", json=datos_vuelo()).status_code == 401
    assert requests.post(f"{base}/api/vuelos", json=datos_vuelo(), headers=usuario["headers"]).status_code == 403
    for ruta, cuerpo in (("ciudades", {"nombre": "Tena"}), ("aerolineas", {"nombre": "X", "codigo": "XX"}),
                         ("aviones", {"nombre": "X", "clases": []})):
        assert requests.post(f"{base}/api/vuelos/{ruta}", json=cuerpo, headers=usuario["headers"]).status_code == 403


def test_coordenadas_de_ciudad_solo_administrador(base, usuario, admin):
    ruta = f"{base}/api/vuelos/ciudades/coordenadas"
    assert requests.get(ruta, params={"nombre": "Tena"}, headers=usuario["headers"]).status_code == 403
    assert requests.get(ruta, params={"nombre": "T"}, headers=admin["headers"]).status_code == 400
    # Con conexión al servicio de mapas devuelve las coordenadas (o 404/503 si no responde)
    resp = requests.get(ruta, params={"nombre": "Tena"}, headers=admin["headers"])
    if resp.status_code == 200:
        datos = resp.json()
        assert -2 < datos["latitud"] < 0 and -79 < datos["longitud"] < -77  # Tena, Napo (Ecuador)
