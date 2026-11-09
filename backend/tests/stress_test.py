"""Script de pruebas destructivas y de estrés para evaluar la robustez,
concurrencia, sesiones y resistencia a colapsos de la arquitectura SOA.
"""
import concurrent.futures
import json
from pathlib import Path
import random
import sys
import time
import uuid
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

BASE_GATEWAY = "http://127.0.0.1:5000"
FRONTEND_URL = "http://127.0.0.1:8080"

resultados = {}


def vuelo_prueba():
    """Id del vuelo UTA-TEST (cambia según la base de datos)."""
    vuelos = requests.get(f"{BASE_GATEWAY}/api/vuelos", params={"origen": "Ambato"}, timeout=10).json()["vuelos"]
    return next(v["id"] for v in vuelos if v["codigo"] == "UTA-TEST")

def log_test(nombre, exitoso, detalle=""):
    print(f"[{'PASS' if exitoso else 'FAIL/VULN'}] {nombre}: {detalle}")
    resultados[nombre] = {"status": "PASS" if exitoso else "FAIL", "detalle": detalle}

def crear_cliente():
    sufijo = uuid.uuid4().hex[:8]
    email = f"stress_{sufijo}@uta.edu.ec"
    pwd = "password1234"
    r = requests.post(f"{BASE_GATEWAY}/api/usuarios", json={"nombre": "Juan Perez", "email": email, "password": pwd}, timeout=10)
    if r.status_code != 201:
        print("Error al crear usuario:", r.status_code, r.text)
        return None
    login = requests.post(f"{BASE_GATEWAY}/api/auth/login", json={"email": email, "password": pwd}, timeout=10).json()
    return {"email": email, "id": login["usuario"]["id"], "token": login["token"], "headers": {"Authorization": f"Bearer {login['token']}"}}

def limpiar_vuelo_225():
    from common.db import engine
    from sqlalchemy import text
    with engine.begin() as con:
        con.execute(text("SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST' FOR UPDATE"))  # bloquea el vuelo antes de tocar asientos
        con.execute(text("DELETE FROM vuelos.asientos WHERE vuelo_id = (SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST')"))
        con.execute(text("DELETE FROM reservas.reservas WHERE vuelo_id = (SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST')"))
        con.execute(text("UPDATE vuelos.vuelos SET fecha_salida = LOCALTIMESTAMP + INTERVAL '1 day', fecha_llegada = LOCALTIMESTAMP + INTERVAL '1480 minutes' WHERE codigo = 'UTA-TEST'"))

def test_1_fuerza_bruta_concurrencia_50_hilos():
    limpiar_vuelo_225()
    """50 hilos intentando retener el MISMO asiento simultáneamente en el vuelo 225."""
    print("\n--- Test 1: 50 clientes simultáneos por el mismo asiento (Race Condition) ---")
    usuarios = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
        usuarios = list(ex.map(lambda _: crear_cliente(), range(50)))
    usuarios = [u for u in usuarios if u is not None]
    
    url = f"{BASE_GATEWAY}/api/vuelos/{vuelo_prueba()}/asientos/36A/retener"
    
    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as pool:
        respuestas = list(pool.map(lambda u: requests.post(url, headers=u["headers"], timeout=15), usuarios))
    duracion = time.time() - start
    
    codigos = [r.status_code for r in respuestas]
    conteo_200 = codigos.count(200)
    conteo_409 = codigos.count(409)
    otros = [c for c in codigos if c not in (200, 409)]
    
    # Debe haber exactamente 1 ganador (200) y 49 rechazados (409). Cero 500s.
    exito = (conteo_200 == 1) and (len(otros) == 0)
    log_test("Race Condition 50 Hilos (1 asiento)", exito, 
             f"200 OK: {conteo_200}, 409 Conflict: {conteo_409}, Errores/500/503: {otros}. Tiempo: {duracion:.2f}s")

def test_2_reserva_masiva_concurrente_distintos_asientos():
    limpiar_vuelo_225()
    """30 usuarios intentan reservar asientos DISTINTOS simultáneamente."""
    print("\n--- Test 2: Reserva masiva simultánea de distintos asientos (30 transacciones) ---")
    usuarios = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
        usuarios = list(ex.map(lambda _: crear_cliente(), range(30)))
    usuarios = [u for u in usuarios if u is not None]
    
    # Asientos válidos en el A340-600
    asientos = [f"{fila}{letra}" for fila in range(35, 45) for letra in ('A', 'C', 'D')][:len(usuarios)]
    
    def hacer_reserva(item):
        u, asiento = item
        payload = {
            "vuelo_id": vuelo_prueba(),
            "pasajeros": [{
                "asiento": asiento,
                "nombre": "Pasajero Prueba",
                "tipo_documento": "PASAPORTE",
                "documento": f"P{random.randint(1000000, 9999999)}"
            }]
        }
        return requests.post(f"{BASE_GATEWAY}/api/reservas", headers=u["headers"], json=payload, timeout=20)
    
    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=15) as pool:
        respuestas = list(pool.map(hacer_reserva, zip(usuarios, asientos)))
    duracion = time.time() - start
    
    codigos = [r.status_code for r in respuestas]
    conteo_201 = codigos.count(201)
    otros = [c for c in codigos if c != 201]
    
    exito = (conteo_201 == len(usuarios))
    log_test("Reserva Masiva 30 Hilos Concurrentes", exito,
             f"201 Creadas: {conteo_201}/{len(usuarios)}, Otros códigos: {otros}. Tiempo: {duracion:.2f}s")

def test_3_ataque_payload_gigante_dos():
    """Intento de colapso enviando payloads anormalmente grandes (DoS de memoria y parsing)."""
    print("\n--- Test 3: Ataque de Payload Gigante (DoS) ---")
    u = crear_cliente()
    # 5 MB de datos basura en JSON
    payload_gigante = {
        "vuelo_id": vuelo_prueba(),
        "pasajeros": [{
            "asiento": "31A",
            "nombre": "A" * (2 * 1024 * 1024),
            "tipo_documento": "PASAPORTE",
            "documento": "B" * 500000
        }]
    }
    try:
        r = requests.post(f"{BASE_GATEWAY}/api/reservas", headers=u["headers"], json=payload_gigante, timeout=10)
        # La app no debe colapsar con 500, sino rechazar con 400 por validación de campos
        log_test("Payload 2MB String DoS", r.status_code == 400, f"Status: {r.status_code}, Res: {r.text[:120]}")
    except Exception as e:
        log_test("Payload 2MB String DoS", False, f"Servidor colapsó o timeout: {e}")

def test_4_inyeccion_sql_en_parametros_y_rutas():
    """Intentos de SQL Injection en endpoints de búsqueda y filtros."""
    print("\n--- Test 4: Pruebas de SQL Injection ---")
    sqli_payloads = [
        "' OR '1'='1",
        "1; DROP TABLE vuelos.asientos;--",
        "Quito' UNION SELECT null, null, null, null, null, null, null, null, null--",
        "'; EXEC xp_cmdshell('dir');--"
    ]
    
    colapsos = []
    for payload in sqli_payloads:
        # Búsqueda de vuelos
        r = requests.get(f"{BASE_GATEWAY}/api/vuelos", params={"origen": payload}, timeout=5)
        if r.status_code == 500:
            colapsos.append((payload, r.status_code, r.text))
        # Retención de asiento con SQLi
        r_asiento = requests.post(f"{BASE_GATEWAY}/api/vuelos/{vuelo_prueba()}/asientos/{payload}/retener", timeout=5)
        if r_asiento.status_code == 500:
            colapsos.append((payload, r_asiento.status_code, r_asiento.text))
            
    exito = (len(colapsos) == 0)
    log_test("Inyección SQL (Filtros y Rutas)", exito, 
             "Protegido con parámetros bind / 404 / 401" if exito else f"Colapsó con 500 en: {colapsos}")

def test_5_manipulacion_jwt_y_sesiones():
    limpiar_vuelo_225()
    """Falsificación de tokens, 'none' algorithm, expiración y suplantación."""
    print("\n--- Test 5: Manipulación de Sesiones y Tokens JWT ---")
    u1 = crear_cliente()
    u2 = crear_cliente()
    
    # 5.1 Token 'none' algorithm (vulnerabilidad clásica de JWT)
    header_none = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0" # {"alg":"none","typ":"JWT"}
    body_admin = "eyJzdWIiOiIxIiwibm9tYnJlIjoiQWRtaW4iLCJlbWFpbCI6ImFkbWluQHV0YS5lZHUuZWMiLCJleHAiOjE5OTk5OTk5OTl9"
    token_none = f"{header_none}.{body_admin}."
    
    r_none = requests.get(f"{BASE_GATEWAY}/api/reservas", headers={"Authorization": f"Bearer {token_none}"})
    vulnerable_none = (r_none.status_code == 200)
    
    # 5.2 Token con firma alterada (tampering)
    token_alterado = u1["token"][:-4] + "wxyz"
    r_tamper = requests.get(f"{BASE_GATEWAY}/api/reservas", headers={"Authorization": f"Bearer {token_alterado}"})
    vulnerable_tamper = (r_tamper.status_code == 200)
    
    # 5.3 Usuario A intenta ver o cancelar reserva de Usuario B
    # Creamos reserva para U2
    payload = {
        "vuelo_id": vuelo_prueba(),
        "pasajeros": [{"asiento": "42A", "nombre": "Persona U2", "tipo_documento": "PASAPORTE", "documento": "P9876543"}]
    }
    r_res = requests.post(f"{BASE_GATEWAY}/api/reservas", headers=u2["headers"], json=payload).json()
    reserva_id = r_res.get("reserva", {}).get("id")
    
    # U1 intenta ver la reserva de U2
    r_get_ajeno = requests.get(f"{BASE_GATEWAY}/api/reservas/{reserva_id}", headers=u1["headers"])
    # U1 intenta cancelar la reserva de U2
    r_del_ajeno = requests.delete(f"{BASE_GATEWAY}/api/reservas/{reserva_id}", headers=u1["headers"])
    
    log_test("JWT Algoritmo 'none' Rechazado", not vulnerable_none, f"Status: {r_none.status_code}")
    log_test("JWT Firma Alterada Rechazada", not vulnerable_tamper, f"Status: {r_tamper.status_code}")
    log_test("Aislamiento entre Sesiones (IDOR)", (r_get_ajeno.status_code == 403 and r_del_ajeno.status_code == 403),
             f"Get Ajeno: {r_get_ajeno.status_code}, Cancelar Ajeno: {r_del_ajeno.status_code}")

def test_6_corrupcion_de_datos_y_tipos_invalidos():
    """Valores nulos, tipos invertidos, números gigantes, caracteres de control."""
    print("\n--- Test 6: Tipos inválidos y Caracteres Especiales ---")
    u = crear_cliente()
    casos = [
        ("Vuelo ID negativo", {"vuelo_id": -99, "pasajeros": []}),
        ("Vuelo ID flotante", {"vuelo_id": vuelo_prueba() + 0.5, "pasajeros": []}),
        ("Vuelo ID string", {"vuelo_id": "abc", "pasajeros": []}),
        ("Vuelo ID entero gigante (Overflow)", {"vuelo_id": 9999999999999999999999999999999999, "pasajeros": []}),
        ("Caracteres nulos en nombre", {"vuelo_id": vuelo_prueba(), "pasajeros": [{"asiento": "31A", "nombre": "Juan\x00Perez", "tipo_documento": "CEDULA", "documento": "1710034065"}]}),
        ("Inyección XSS en nombre", {"vuelo_id": vuelo_prueba(), "pasajeros": [{"asiento": "31A", "nombre": "<script>alert('pwned')</script>", "tipo_documento": "CEDULA", "documento": "1710034065"}]}),
        ("JSON Malformado", " esto no es json {{{{ ")
    ]
    
    errores_500 = []
    for desc, body in casos:
        if isinstance(body, str):
            h = {"Content-Type": "application/json", **u["headers"]}
            r = requests.post(f"{BASE_GATEWAY}/api/reservas", headers=h, data=body)
        else:
            r = requests.post(f"{BASE_GATEWAY}/api/reservas", headers=u["headers"], json=body)
        if r.status_code >= 500:
            errores_500.append((desc, r.status_code, r.text))
        else:
            print(f"  OK: {desc} manejado limpiamente con código {r.status_code}")
            
    exito = (len(errores_500) == 0)
    log_test("Manejo de Tipos y Payloads Malformados", exito,
             "Todas las excepciones capturadas con 400/404" if exito else f"Error 500 en: {errores_500}")

def test_7_cors_y_swagger_pdf_compliance():
    """Verificación de endpoints Swagger, CORS, y entrega de frontend."""
    print("\n--- Test 7: Cumplimiento de Requisitos del PDF ---")
    
    # 1. Frontend responde
    r_front = requests.get(FRONTEND_URL)
    front_ok = (r_front.status_code == 200 and "Gestión de Reservas" in r_front.text or "html" in r_front.text.lower())
    
    # 2. CORS preflight (OPTIONS)
    r_options = requests.options(f"{BASE_GATEWAY}/api/reservas", headers={
        "Origin": "http://localhost:8080",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "Authorization, Content-Type"
    })
    cors_ok = (r_options.status_code == 200 and r_options.headers.get("Access-Control-Allow-Origin") == "*")
    
    # 3. Swagger docs disponibles
    swaggers = {}
    for puerto, nombre in [(5001, "Usuarios"), (5002, "Auth"), (5003, "Vuelos"), (5004, "Reservas")]:
        r = requests.get(f"http://127.0.0.1:{puerto}/apidocs/", timeout=3)
        swaggers[nombre] = r.status_code == 200
    
    swagger_ok = all(swaggers.values())
    
    log_test("Frontend Operativo (HTTP 8080)", front_ok, f"Status: {r_front.status_code}")
    log_test("CORS Preflight en Gateway", cors_ok, f"Status: {r_options.status_code}, Allow-Origin: {r_options.headers.get('Access-Control-Allow-Origin')}")
    log_test("Documentación Swagger de Servicios (SOA Contratos)", swagger_ok, f"Detalle: {swaggers}")

if __name__ == "__main__":
    print("="*70)
    print("INICIANDO SUITE DE PRUEBAS DE ESTRÉS, SEGURIDAD Y COLAPSO")
    print("="*70)
    test_1_fuerza_bruta_concurrencia_50_hilos()
    test_2_reserva_masiva_concurrente_distintos_asientos()
    test_3_ataque_payload_gigante_dos()
    test_4_inyeccion_sql_en_parametros_y_rutas()
    test_5_manipulacion_jwt_y_sesiones()
    test_6_corrupcion_de_datos_y_tipos_invalidos()
    test_7_cors_y_swagger_pdf_compliance()
    print("="*70)
    print("RESUMEN FINAL DE PRUEBAS:")
    print(json.dumps(resultados, indent=2))
