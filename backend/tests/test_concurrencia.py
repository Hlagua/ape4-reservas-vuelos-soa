"""Pruebas de concurrencia: varios clientes (como si fueran computadoras distintas)
compitiendo por el mismo asiento al mismo tiempo."""
from concurrent.futures import ThreadPoolExecutor

import requests

from tests.conftest import crear_usuario, estado_asiento, pasajero


def test_retener_asiento_y_verlo_bloqueado_desde_otro_cliente(base, usuario, otro_usuario, vuelo_prueba):
    url = f"{base}/api/vuelos/{vuelo_prueba}/asientos/31A/retener"
    assert requests.post(url, headers=usuario["headers"]).status_code == 200

    # El otro usuario no puede tomarlo y lo ve bloqueado; el dueño lo ve como su selección
    resp = requests.post(url, headers=otro_usuario["headers"])
    assert resp.status_code == 409
    assert estado_asiento(vuelo_prueba, "31A", otro_usuario["headers"]) == "BLOQUEADO"
    assert estado_asiento(vuelo_prueba, "31A", usuario["headers"]) == "SELECCIONADO"

    # Solo el dueño puede soltarlo; luego queda libre para el otro
    assert requests.delete(url, headers=otro_usuario["headers"]).status_code == 404
    assert requests.delete(url, headers=usuario["headers"]).status_code == 200
    assert requests.post(url, headers=otro_usuario["headers"]).status_code == 200


def test_retener_validaciones(base, usuario, vuelo_prueba):
    assert requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/31A/retener").status_code == 401
    assert requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/99Z/retener",
                         headers=usuario["headers"]).status_code == 404


def test_maximo_cinco_asientos_por_usuario(base, usuario, vuelo_prueba):
    asientos = ["31A", "31C", "31D", "31E", "31F", "31G"]
    codigos = [requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/{a}/retener",
                             headers=usuario["headers"]).status_code for a in asientos]
    assert codigos == [200] * 5 + [400]


def test_diez_clientes_seleccionan_el_mismo_asiento(base, vuelo_prueba):
    """Solo uno de los 10 clientes simultáneos obtiene el asiento."""
    usuarios = [crear_usuario() for _ in range(10)]
    url = f"{base}/api/vuelos/{vuelo_prueba}/asientos/40D/retener"
    with ThreadPoolExecutor(max_workers=10) as pool:
        codigos = sorted(pool.map(lambda u: requests.post(url, headers=u["headers"]).status_code, usuarios))
    assert codigos == [200] + [409] * 9


def test_diez_clientes_reservan_el_mismo_asiento(base, vuelo_prueba):
    """Reserva directa sin selección previa: solo una reserva se confirma, no hay doble venta."""
    usuarios = [crear_usuario() for _ in range(10)]

    def reservar(u):
        return requests.post(f"{base}/api/reservas", headers=u["headers"],
                             json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("41E")]})

    with ThreadPoolExecutor(max_workers=10) as pool:
        respuestas = list(pool.map(reservar, usuarios))
    codigos = sorted(r.status_code for r in respuestas)
    assert codigos == [201] + [409] * 9

    ganador = next(u for u, r in zip(usuarios, respuestas) if r.status_code == 201)
    assert estado_asiento(vuelo_prueba, "41E", ganador["headers"]) == "RESERVADO"
    assert estado_asiento(vuelo_prueba, "41E") == "OCUPADO"


def test_no_se_puede_reservar_asiento_seleccionado_por_otro(base, usuario, otro_usuario, vuelo_prueba):
    requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/33A/retener", headers=usuario["headers"])
    resp = requests.post(f"{base}/api/reservas", headers=otro_usuario["headers"],
                         json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("33A")]})
    assert resp.status_code == 409
    assert resp.json()["detalle"]["asientos_no_disponibles"] == ["33A"]
