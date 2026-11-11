"""Pruebas del servicio de Reservas e interoperabilidad entre servicios."""
import requests
from sqlalchemy import text

from common.db import engine
from tests.conftest import estado_asiento, pasajero, solo_local


def reservar(base, usuario, vuelo_id, pasajeros):
    return requests.post(f"{base}/api/reservas", json={"vuelo_id": vuelo_id, "pasajeros": pasajeros},
                         headers=usuario["headers"])


def test_flujo_completo_reserva(base, usuario, otro_usuario, vuelo_prueba):
    h = usuario["headers"]
    # Selección de asientos (retención) y reserva con datos de pasajeros
    for a in ("31A", "4C"):
        assert requests.post(f"{base}/api/vuelos/{vuelo_prueba}/asientos/{a}/retener", headers=h).status_code == 200
    resp = reservar(base, usuario, vuelo_prueba, [
        pasajero("31A", "Juan Pérez"),
        {"asiento": "4C", "nombre": "María López", "tipo_documento": "CEDULA", "documento": "1710034065"},
    ])
    assert resp.status_code == 201, resp.text
    reserva = resp.json()["reserva"]
    mapa = requests.get(f"{base}/api/vuelos/{vuelo_prueba}/asientos").json()
    precio = {c["clase"]: c["precio"] for c in mapa["clases"]}
    assert reserva["estado"] == "CONFIRMADA"
    assert reserva["asientos"] == ["31A", "4C"]
    assert reserva["total"] == round(precio["ECONOMY"] + precio["BUSINESS"], 2)
    assert estado_asiento(vuelo_prueba, "31A", h) == "RESERVADO"
    assert estado_asiento(vuelo_prueba, "31A", otro_usuario["headers"]) == "OCUPADO"

    # Consultar
    detalle = requests.get(f"{base}/api/reservas/{reserva['id']}", headers=h).json()
    assert [p["nombre"] for p in detalle["reserva"]["detalle_pasajeros"]] == ["Juan Pérez", "María López"]
    listado = requests.get(f"{base}/api/reservas", headers=h).json()
    assert listado["reservas"][0]["asientos"] == "31A, 4C"

    # Modificar: se cambia 4C por 31C
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h,
                        json={"pasajeros": [pasajero("31A", "Juan Pérez"), pasajero("31C", "María López")]})
    assert resp.status_code == 200
    assert resp.json()["reserva"]["asientos"] == ["31A", "31C"]
    assert estado_asiento(vuelo_prueba, "4C") == "DISPONIBLE"
    assert estado_asiento(vuelo_prueba, "31C") == "OCUPADO"

    # Cancelar: los asientos quedan libres
    resp = requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=h)
    assert resp.status_code == 200
    assert resp.json()["reserva"]["estado"] == "CANCELADA"
    assert estado_asiento(vuelo_prueba, "31A") == "DISPONIBLE"
    assert estado_asiento(vuelo_prueba, "31C") == "DISPONIBLE"


def test_reservar_sin_token(base, vuelo_prueba):
    resp = requests.post(f"{base}/api/reservas", json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("31A")]})
    assert resp.status_code == 401


def test_campos_de_pasajeros_controlados(base, usuario, vuelo_prueba):
    resp = reservar(base, usuario, vuelo_prueba, [
        {"asiento": "31A", "nombre": "J", "tipo_documento": "CEDULA", "documento": "1234567890"},
        {"asiento": "31A", "nombre": "Ana 2", "tipo_documento": "PASAPORTE", "documento": "x"},
    ])
    assert resp.status_code == 400
    detalle = resp.json()["detalle"]
    assert {"pasajeros[0].nombre", "pasajeros[0].documento", "pasajeros[1].nombre",
            "pasajeros[1].documento", "asientos"} <= set(detalle)
    assert detalle["pasajeros[0].documento"] == "Cédula ecuatoriana inválida"


def test_documento_repetido_en_la_reserva(base, usuario, vuelo_prueba):
    p1, p2 = pasajero("31A"), pasajero("31C")
    p2["documento"] = p1["documento"]
    resp = reservar(base, usuario, vuelo_prueba, [p1, p2])
    assert resp.status_code == 400
    assert "documentos" in resp.json()["detalle"]


def test_reservar_sin_pasajeros_o_demasiados(base, usuario, vuelo_prueba):
    assert reservar(base, usuario, vuelo_prueba, []).status_code == 400
    seis = [pasajero(f"3{i}A") for i in range(1, 7)]
    resp = reservar(base, usuario, vuelo_prueba, seis)
    assert resp.status_code == 400
    assert resp.json()["error"] == "Máximo 5 pasajeros por reserva"


def test_reservar_vuelo_o_asiento_inexistente(base, usuario, vuelo_prueba):
    assert reservar(base, usuario, 999999, [pasajero("31A")]).status_code == 404
    assert reservar(base, usuario, vuelo_prueba, [pasajero("99Z")]).status_code == 404


def test_reserva_ajena_prohibida(base, usuario, otro_usuario, vuelo_prueba):
    reserva = reservar(base, usuario, vuelo_prueba, [pasajero("35A")]).json()["reserva"]
    assert requests.get(f"{base}/api/reservas/{reserva['id']}", headers=otro_usuario["headers"]).status_code == 403
    assert requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=otro_usuario["headers"]).status_code == 403


def test_cancelar_dos_veces(base, usuario, vuelo_prueba):
    reserva = reservar(base, usuario, vuelo_prueba, [pasajero("36A")]).json()["reserva"]
    h = usuario["headers"]
    assert requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=h).status_code == 200
    assert requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=h).status_code == 400
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h, json={"pasajeros": [pasajero("36A")]})
    assert resp.status_code == 400


def test_no_se_modifica_ni_cancela_un_vuelo_que_ya_despego(base, usuario, vuelo_prueba):
    reserva = reservar(base, usuario, vuelo_prueba, [pasajero("37A")]).json()["reserva"]
    h = usuario["headers"]
    en_lista = lambda: next(r for r in requests.get(f"{base}/api/reservas", headers=h).json()["reservas"]
                            if r["id"] == reserva["id"])
    assert en_lista()["despegado"] is False and en_lista()["fecha_salida"]
    with engine.begin() as con:
        con.execute(text("SELECT id FROM vuelos.vuelos WHERE id = :v FOR UPDATE"), {"v": vuelo_prueba})
        con.execute(text("""
            UPDATE vuelos.vuelos SET fecha_salida = LOCALTIMESTAMP - INTERVAL '1 hour',
                   fecha_llegada = LOCALTIMESTAMP + INTERVAL '3 hours' WHERE id = :v"""), {"v": vuelo_prueba})
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h, json={"pasajeros": [pasajero("37B")]})
    assert resp.status_code == 400 and "despegó" in resp.json()["error"]
    resp = requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=h)
    assert resp.status_code == 400 and "despegó" in resp.json()["error"]
    detalle = requests.get(f"{base}/api/reservas/{reserva['id']}", headers=h).json()["reserva"]
    assert detalle["estado"] == "CONFIRMADA" and detalle["asientos"] == ["37A"]
    assert en_lista()["despegado"] is True  # la app oculta Modificar y Cancelar



def test_cambio_de_clase_cobra_solo_la_diferencia_o_la_devuelve(base, usuario, vuelo_prueba):
    h = usuario["headers"]
    precio = {c["clase"]: c["precio"] for c in requests.get(f"{base}/api/vuelos/{vuelo_prueba}/asientos").json()["clases"]}
    iva = lambda v: round(v * 1.15, 2)  # noqa: E731
    juan, ana = pasajero("38A", "Juan Perez"), pasajero("38C", "Ana Ruiz")
    reserva = reservar(base, usuario, vuelo_prueba, [juan, ana]).json()["reserva"]
    pagado = reserva["total"]
    assert pagado == round(2 * precio["ECONOMY"], 2)

    # Juan pasa de Economy a Business: se cobra solo la diferencia, no la reserva completa
    juan_b = {**juan, "asiento": "5C"}
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h, json={"pasajeros": [juan_b, ana]})
    assert resp.status_code == 200, resp.text
    ajuste = resp.json()["ajuste"]
    sube = round(precio["BUSINESS"] - precio["ECONOMY"], 2)
    assert ajuste["tipo"] == "COBRO" and ajuste["diferencia"] == sube
    assert ajuste["total_anterior"] == pagado and ajuste["total_nuevo"] == round(pagado + sube, 2)
    assert ajuste["diferencia_con_iva"] == round(iva(pagado + sube) - iva(pagado), 2)

    # Solo cambia un nombre: el precio no cambia
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h,
                        json={"pasajeros": [{**juan_b, "nombre": "Juan Pablo Perez"}, ana]})
    assert resp.json()["ajuste"]["tipo"] == "SIN_CAMBIO" and resp.json()["ajuste"]["diferencia"] == 0

    # Vuelve a Economy: se le devuelve la diferencia
    resp = requests.put(f"{base}/api/reservas/{reserva['id']}", headers=h, json={"pasajeros": [juan, ana]})
    ajuste = resp.json()["ajuste"]
    assert ajuste["tipo"] == "DEVOLUCION" and ajuste["diferencia"] == -sube and ajuste["total_nuevo"] == pagado

    # Los ajustes quedan registrados en la reserva
    ajustes = requests.get(f"{base}/api/reservas/{reserva['id']}", headers=h).json()["reserva"]["ajustes"]
    assert [a["tipo"] for a in ajustes] == ["COBRO", "DEVOLUCION"]

@solo_local
def test_servicio_vuelos_caido_responde_503(usuario, vuelo_prueba):
    """Interoperabilidad: si Vuelos no responde, Reservas devuelve 503 controlado."""
    from servicio_reservas.app import app as reservas_app

    original = reservas_app.config["VUELOS_URL"]
    reservas_app.config["VUELOS_URL"] = "http://127.0.0.1:5999"  # puerto sin servicio
    try:
        resp = reservas_app.test_client().post("/api/reservas", headers=usuario["headers"],
                                               json={"vuelo_id": vuelo_prueba, "pasajeros": [pasajero("31A")]})
        assert resp.status_code == 503
        assert resp.get_json()["error"] == "Servicio no disponible"
    finally:
        reservas_app.config["VUELOS_URL"] = original
