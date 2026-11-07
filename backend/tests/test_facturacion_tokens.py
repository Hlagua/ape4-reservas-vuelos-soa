"""Pruebas del servicio de Facturación (XML) y de la tabla de tokens (cierre de sesión)."""
import xml.etree.ElementTree as ET

import requests

from tests.conftest import pasajero


def reservar(base, usuario, vuelo_id, asientos):
    resp = requests.post(f"{base}/api/reservas", headers=usuario["headers"],
                         json={"vuelo_id": vuelo_id, "pasajeros": [pasajero(a) for a in asientos]})
    assert resp.status_code == 201, resp.text
    return resp.json()["reserva"]


# ---------- Facturación ----------

def test_factura_de_reserva_en_xml_con_iva(base, usuario, vuelo_prueba):
    reserva = reservar(base, usuario, vuelo_prueba, ["31A", "4C"])
    resp = requests.get(f"{base}/api/facturas/reserva/{reserva['id']}", headers=usuario["headers"])
    assert resp.status_code == 200
    assert resp.headers["Content-Type"].startswith("application/xml")

    factura = ET.fromstring(resp.content)
    assert factura.findtext("Cabecera/Numero") == f"F001-{reserva['id']:09d}"
    assert len(factura.findall("detalle/producto")) == 2
    subtotal = float(factura.findtext("totales/Subtotal"))
    assert subtotal == reserva["total"]
    assert float(factura.findtext("totales/IVA")) == round(subtotal * 0.15, 2)
    assert float(factura.findtext("totales/Total")) == round(subtotal * 1.15, 2)
    assert factura.findtext("Vuelo/Codigo") == "UTA-TEST"


def test_factura_de_reserva_ajena_o_cancelada(base, usuario, otro_usuario, vuelo_prueba):
    reserva = reservar(base, usuario, vuelo_prueba, ["32A"])
    url = f"{base}/api/facturas/reserva/{reserva['id']}"
    assert requests.get(url).status_code == 401
    assert requests.get(url, headers=otro_usuario["headers"]).status_code == 403
    requests.delete(f"{base}/api/reservas/{reserva['id']}", headers=usuario["headers"])
    assert requests.get(url, headers=usuario["headers"]).status_code == 400


def test_factura_desde_json_contrato_de_clase(base):
    datos = {
        "factura": {"numero": "F001-000010", "fecha": "2026-11-07"},
        "cliente": {"nombre": "Ana López", "cedula_ruc": "1804567890"},
        "detalles": [{"nombre": "Laptop", "cantidad": 2, "precio_unitario": 500},
                     {"nombre": "Mouse", "cantidad": 1, "precio_unitario": 20}],
    }
    resp = requests.post(f"{base}/api/facturas", json=datos)
    assert resp.status_code == 200
    factura = ET.fromstring(resp.content)
    assert factura.findtext("totales/Subtotal") == "1020.00"
    assert factura.findtext("totales/IVA") == "153.00"
    assert factura.findtext("totales/Total") == "1173.00"


def test_factura_datos_invalidos(base):
    resp = requests.post(f"{base}/api/facturas", json={
        "factura": {"numero": "F1"}, "cliente": {"nombre": "Ana"},
        "detalles": [{"nombre": "", "cantidad": "x", "precio_unitario": -1}],
    })
    assert resp.status_code == 400
    cuerpo = resp.json()
    assert cuerpo["estado"] == "error"
    campos = {e["campo"] for e in cuerpo["errores"]}
    assert {"fecha", "cliente.cedula_ruc", "detalles[0].nombre", "detalles[0].cantidad",
            "detalles[0].precio_unitario"} <= campos


# ---------- Tokens y perfil ----------

def test_registro_por_ruta_registro(base):
    import uuid
    resp = requests.post(f"{base}/api/usuarios/registro", json={
        "nombre": "Ana Ruiz", "email": f"reg_{uuid.uuid4().hex[:6]}@uta.edu.ec", "password": "clave1234"})
    assert resp.status_code == 201


def test_perfil_del_usuario(base, usuario):
    resp = requests.get(f"{base}/api/usuarios/perfil", headers=usuario["headers"])
    assert resp.status_code == 200
    assert resp.json()["email"] == usuario["email"]
    assert requests.get(f"{base}/api/usuarios/perfil").status_code == 401


def test_logout_revoca_el_token_en_todos_los_servicios(base, usuario):
    h = usuario["headers"]
    assert requests.get(f"{base}/api/reservas", headers=h).status_code == 200
    assert requests.post(f"{base}/api/auth/logout", headers=h).status_code == 200
    assert requests.get(f"{base}/api/reservas", headers=h).status_code == 401
    assert requests.get(f"{base}/api/usuarios/perfil", headers=h).status_code == 401
    resp = requests.get(f"{base}/api/auth/verificar", headers=h)
    assert resp.status_code == 401
    assert resp.json()["error"] == "La sesión fue cerrada, vuelva a iniciar sesión"
    # Un nuevo login entrega otro token válido
    nuevo = requests.post(f"{base}/api/auth/login", json={"email": usuario["email"], "password": usuario["password"]})
    assert requests.get(f"{base}/api/reservas",
                        headers={"Authorization": f"Bearer {nuevo.json()['token']}"}).status_code == 200
