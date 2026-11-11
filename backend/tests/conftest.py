"""Pruebas funcionales: requieren el backend levantado con `python run_backend.py`."""
import os
import uuid

import pytest
import requests
from sqlalchemy import text

from common import config
from common.db import engine

# Por defecto el backend local; para probar el desplegado: API_URL=https://<servicio>.onrender.com
GATEWAY = os.getenv("API_URL", f"http://127.0.0.1:{config.GATEWAY_PORT}").rstrip("/")
REMOTO = not GATEWAY.startswith("http://127.0.0.1")
solo_local = pytest.mark.skipif(REMOTO, reason="Necesita acceso directo a los servicios internos (solo en local)")


@pytest.fixture(scope="session", autouse=True)
def sistema_activo():
    try:
        requests.get(f"{GATEWAY}/api/salud", timeout=3)
    except requests.RequestException:
        pytest.exit("El backend no está levantado. Ejecute primero: python run_backend.py", returncode=1)


@pytest.fixture
def base():
    return GATEWAY


def crear_usuario():
    sufijo = uuid.uuid4().hex[:8]
    datos = {"nombre": "Usuario Prueba", "email": f"test_{sufijo}@uta.edu.ec", "password": "clave1234"}
    resp = requests.post(f"{GATEWAY}/api/usuarios", json=datos)
    assert resp.status_code == 201, resp.text
    login = requests.post(f"{GATEWAY}/api/auth/login", json={"email": datos["email"], "password": datos["password"]})
    assert login.status_code == 200
    cuerpo = login.json()
    return {**datos, "id": cuerpo["usuario"]["id"], "rol": cuerpo["usuario"]["rol"], "token": cuerpo["token"],
            "headers": {"Authorization": f"Bearer {cuerpo['token']}"}}


@pytest.fixture
def admin():
    """Administrador de ejemplo (database/init_db.py): ingresa con email y contraseña como cualquier usuario."""
    from database.init_db import USUARIO_ADMIN
    login = requests.post(f"{GATEWAY}/api/auth/login",
                          json={"email": USUARIO_ADMIN["email"], "password": USUARIO_ADMIN["password"]})
    assert login.status_code == 200, login.text
    cuerpo = login.json()
    return {"id": cuerpo["usuario"]["id"], "rol": cuerpo["usuario"]["rol"],
            "headers": {"Authorization": f"Bearer {cuerpo['token']}"}}


@pytest.fixture
def usuario():
    return crear_usuario()


@pytest.fixture
def otro_usuario():
    return crear_usuario()


@pytest.fixture
def vuelo_prueba():
    """Vuelo UTA-TEST vacío y con salida mañana (se reinicia en cada prueba)."""
    with engine.begin() as con:
        # Se bloquea el vuelo primero, igual que el servicio de Vuelos, para no chocar con el trigger
        vuelo_id = con.execute(text("SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST' FOR UPDATE")).scalar()
        con.execute(text("DELETE FROM vuelos.asientos WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("DELETE FROM reservas.reservas WHERE vuelo_id = :v"), {"v": vuelo_id})
        con.execute(text("""
            UPDATE vuelos.vuelos SET fecha_salida = LOCALTIMESTAMP + INTERVAL '1 day',
                   fecha_llegada = LOCALTIMESTAMP + INTERVAL '1480 minutes' WHERE id = :v"""), {"v": vuelo_id})
    return vuelo_id


def pasajero(asiento, nombre="Juan Perez"):
    """Pasajero válido con pasaporte único."""
    return {"asiento": asiento, "nombre": nombre, "tipo_documento": "PASAPORTE",
            "documento": "P" + uuid.uuid4().hex[:7].upper()}


def estado_asiento(vuelo_id, asiento, headers=None):
    mapa = requests.get(f"{GATEWAY}/api/vuelos/{vuelo_id}/asientos", headers=headers or {}).json()
    return mapa["estados"].get(asiento, "DISPONIBLE")
