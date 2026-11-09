"""Comportamiento cuando la base de datos no responde (sin apagar la base real)."""
import requests
from flask import Flask
from sqlalchemy.exc import OperationalError

from common.errores import registrar_manejadores
from tests.conftest import GATEWAY


def test_error_de_conexion_a_la_base_responde_503():
    app = Flask(__name__)
    registrar_manejadores(app)

    @app.get("/consulta")
    def consulta():
        raise OperationalError("SELECT 1", {}, Exception("connection refused"))

    resp = app.test_client().get("/consulta")
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "Base de datos no disponible"


def test_salud_informa_el_estado_de_la_base():
    datos = requests.get(f"{GATEWAY}/api/salud", timeout=60).json()
    assert datos["base_datos"] == "activa"
    assert all(s["estado"] == "activo" for s in datos["servicios"].values())
