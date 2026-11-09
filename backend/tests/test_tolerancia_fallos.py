"""Tolerancia a fallos: se apaga cada servicio y se comprueba qué sigue funcionando.

Requiere ADMIN_KEY (backend/.env) igual a la del backend. Funciona en local y contra Render:
    API_URL=https://aeroreservas-backend.onrender.com python -m pytest tests/test_tolerancia_fallos.py
"""
from contextlib import contextmanager

import pytest
import requests

from common import config
from tests.conftest import GATEWAY, crear_usuario, pasajero

ADMIN = {"X-Admin-Key": config.ADMIN_KEY}


def _admin_disponible():
    try:
        return requests.get(f"{GATEWAY}/api/admin/servicios", headers=ADMIN, timeout=90).status_code == 200
    except requests.RequestException:
        return False


pytestmark = pytest.mark.skipif(not config.ADMIN_KEY or not _admin_disponible(),
                                reason="Administración no disponible (falta ADMIN_KEY o no coincide con el backend)")


@contextmanager
def servicio_caido(clave):
    """Detiene un servicio durante el bloque y siempre lo vuelve a iniciar."""
    resp = requests.post(f"{GATEWAY}/api/admin/servicios/{clave}/detener", headers=ADMIN, timeout=60)
    assert resp.status_code == 200, resp.text
    try:
        salud = requests.get(f"{GATEWAY}/api/salud", timeout=60).json()["servicios"]
        assert salud[clave]["estado"] == "caído"
        assert all(s["estado"] == "activo" for c, s in salud.items() if c != clave)
        yield
    finally:
        resp = requests.post(f"{GATEWAY}/api/admin/servicios/{clave}/iniciar", headers=ADMIN, timeout=120)
        assert resp.status_code == 200, resp.text


@pytest.fixture
def escenario(vuelo_prueba):
    """Usuario con sesión iniciada y una reserva confirmada (antes de apagar nada)."""
    usuario = crear_usuario()
    reserva = requests.post(f"{GATEWAY}/api/reservas", headers=usuario["headers"],
                            json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("31A")]}).json()["reserva"]
    return {"usuario": usuario, "h": usuario["headers"], "vuelo": vuelo_prueba, "reserva": reserva["id"]}


def get(ruta, **kw):
    return requests.get(f"{GATEWAY}{ruta}", timeout=60, **kw).status_code


def post(ruta, **kw):
    return requests.post(f"{GATEWAY}{ruta}", timeout=60, **kw).status_code


def login(usuario):
    return post("/api/auth/login", json={"email": usuario["email"], "password": usuario["password"]})


def test_cae_facturacion(escenario):
    e = escenario
    with servicio_caido("facturas"):
        assert get(f"/api/facturas/reserva/{e['reserva']}", headers=e["h"]) == 503
        assert post("/api/facturas", json={"factura": {}}) == 503
        # Todo lo demás sigue funcionando
        assert login(e["usuario"]) == 200
        assert get("/api/vuelos") == 200
        assert get("/api/reservas", headers=e["h"]) == 200
    assert get(f"/api/facturas/reserva/{e['reserva']}", headers=e["h"]) == 200


def test_cae_reservas(escenario):
    e = escenario
    with servicio_caido("reservas"):
        assert get("/api/reservas", headers=e["h"]) == 503
        assert post("/api/reservas", headers=e["h"], json={"vuelo_id": e["vuelo"], "cantidad": 1}) == 503
        assert get(f"/api/facturas/reserva/{e['reserva']}", headers=e["h"]) == 503
        # Login, búsqueda, mapa y selección de asientos siguen funcionando
        assert login(e["usuario"]) == 200
        assert get("/api/vuelos") == 200
        assert get(f"/api/vuelos/{e['vuelo']}/asientos", headers=e["h"]) == 200
        assert post(f"/api/vuelos/{e['vuelo']}/asientos/32A/retener", headers=e["h"]) == 200
    assert get("/api/reservas", headers=e["h"]) == 200


def test_cae_vuelos(escenario):
    e = escenario
    with servicio_caido("vuelos"):
        assert get("/api/vuelos") == 503
        assert post("/api/reservas", headers=e["h"], json={"vuelo_id": e["vuelo"], "cantidad": 1}) == 503
        # Cancelar necesita a Vuelos para liberar asientos: se rechaza sin dejar datos a medias
        resp = requests.delete(f"{GATEWAY}/api/reservas/{e['reserva']}", headers=e["h"], timeout=60)
        assert resp.status_code == 503
        # Sesión, perfil y la lista de reservas siguen funcionando
        assert login(e["usuario"]) == 200
        assert get("/api/usuarios/perfil", headers=e["h"]) == 200
        assert get("/api/reservas", headers=e["h"]) == 200
    reservas = requests.get(f"{GATEWAY}/api/reservas", headers=e["h"], timeout=60).json()["reservas"]
    assert reservas[0]["estado"] == "CONFIRMADA"  # la cancelación fallida no cambió nada


def test_cae_usuarios(escenario):
    e = escenario
    with servicio_caido("usuarios"):
        assert login(e["usuario"]) == 503
        assert post("/api/usuarios/registro", json={"nombre": "Ana Ruiz", "email": "x@uta.edu.ec",
                                                    "password": "clave1234"}) == 503
        assert get("/api/usuarios/perfil", headers=e["h"]) == 503
        # Quien ya tenía sesión sigue buscando, reservando y facturando
        assert get("/api/vuelos") == 200
        assert get("/api/reservas", headers=e["h"]) == 200
        assert post("/api/reservas", headers=e["h"], json={"vuelo_id": e["vuelo"], "cantidad": 1}) == 201
        assert get(f"/api/facturas/reserva/{e['reserva']}", headers=e["h"]) == 200
    assert login(e["usuario"]) == 200


def test_cae_autenticacion(escenario):
    e = escenario
    with servicio_caido("auth"):
        assert login(e["usuario"]) == 503
        assert get("/api/reservas", headers=e["h"]) == 503
        # Lo público sigue funcionando: búsqueda y mapa sin sesión
        assert get("/api/vuelos") == 200
        assert get(f"/api/vuelos/{e['vuelo']}/asientos") == 200
    assert get("/api/reservas", headers=e["h"]) == 200


def test_admin_protegido():
    assert get("/api/admin/servicios") == 403
    assert get("/api/admin/servicios", headers={"X-Admin-Key": "incorrecta"}) == 403
    assert post("/api/admin/servicios/gateway/detener", headers=ADMIN) == 400
