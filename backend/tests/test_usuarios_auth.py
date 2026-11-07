"""Pruebas de los servicios de Usuarios y Autenticación."""
import requests


# ---------- Registro de usuarios ----------

def test_registro_exitoso(base, usuario):
    assert usuario["id"] > 0


def test_registro_email_duplicado(base, usuario):
    resp = requests.post(f"{base}/api/usuarios",
                         json={"nombre": "Otro Usuario", "email": usuario["email"], "password": "clave1234"})
    assert resp.status_code == 409
    assert resp.json()["error"] == "El email ya está registrado"


def test_registro_campos_controlados(base):
    resp = requests.post(f"{base}/api/usuarios", json={"nombre": "J0hn", "email": "no-es-email", "password": "corta"})
    assert resp.status_code == 400
    detalle = resp.json()["detalle"]
    assert set(detalle) == {"nombre", "email", "password"}


def test_registro_password_sin_numeros(base):
    resp = requests.post(f"{base}/api/usuarios",
                         json={"nombre": "Ana Ruiz", "email": "ana_sin_num@uta.edu.ec", "password": "solamenteletras"})
    assert resp.status_code == 400
    assert "número" in resp.json()["detalle"]["password"]


def registrar(base, nombre="Ana Ruiz", email="ana_reglas@uta.edu.ec", password="clave1234"):
    return requests.post(f"{base}/api/usuarios", json={"nombre": nombre, "email": email, "password": password})


def test_email_sin_mayusculas(base):
    resp = registrar(base, email="Ana.Ruiz@uta.edu.ec")
    assert resp.status_code == 400
    assert resp.json()["detalle"]["email"] == "No se permiten letras mayúsculas"


def test_email_sin_espacios_al_inicio_final_ni_en_medio(base):
    for email in (" ana@uta.edu.ec", "ana@uta.edu.ec ", "ana ruiz@uta.edu.ec"):
        resp = registrar(base, email=email)
        assert resp.status_code == 400, email
        assert resp.json()["detalle"]["email"] == "No se permiten espacios"


def test_email_maximo_50_caracteres(base):
    email = "a" * 40 + "@uta.edu.ec"  # 51 caracteres
    resp = registrar(base, email=email)
    assert resp.status_code == 400
    assert resp.json()["detalle"]["email"] == "Máximo 50 caracteres"


def test_nombre_maximo_60_caracteres(base):
    resp = registrar(base, nombre="A" * 61)
    assert resp.status_code == 400
    assert resp.json()["detalle"]["nombre"] == "Debe tener entre 3 y 60 caracteres"
    resp = registrar(base, nombre=" Ana Ruiz")
    assert resp.json()["detalle"]["nombre"].startswith("Solo se permiten letras")


def test_password_sin_espacios(base):
    resp = registrar(base, password="clave 1234")
    assert resp.status_code == 400
    assert resp.json()["detalle"]["password"] == "La contraseña no puede contener espacios"


def test_registro_sin_json(base):
    resp = requests.post(f"{base}/api/usuarios", data="texto plano")
    assert resp.status_code == 400
    assert resp.json()["error"] == "Debe enviar un JSON"


def test_consultar_usuario_propio(base, usuario):
    resp = requests.get(f"{base}/api/usuarios/{usuario['id']}", headers=usuario["headers"])
    assert resp.status_code == 200
    assert resp.json()["email"] == usuario["email"]
    assert "password_hash" not in resp.json()


def test_consultar_otro_usuario_prohibido(base, usuario, otro_usuario):
    resp = requests.get(f"{base}/api/usuarios/{otro_usuario['id']}", headers=usuario["headers"])
    assert resp.status_code == 403


def test_consultar_usuario_sin_token(base, usuario):
    assert requests.get(f"{base}/api/usuarios/{usuario['id']}").status_code == 401


# ---------- Autenticación ----------

def test_login_devuelve_token(base, usuario):
    resp = requests.post(f"{base}/api/auth/login", json={"email": usuario["email"], "password": usuario["password"]})
    assert resp.status_code == 200
    assert resp.json()["tipo"] == "Bearer"
    assert resp.json()["token"].count(".") == 2  # formato JWT


def test_login_password_incorrecta(base, usuario):
    resp = requests.post(f"{base}/api/auth/login", json={"email": usuario["email"], "password": "incorrecta1"})
    assert resp.status_code == 401


def test_login_faltan_datos(base):
    assert requests.post(f"{base}/api/auth/login", json={"email": "x@uta.edu.ec"}).status_code == 400


def test_verificar_token_valido(base, usuario):
    resp = requests.get(f"{base}/api/auth/verificar", headers=usuario["headers"])
    assert resp.status_code == 200
    assert resp.json()["usuario"]["id"] == usuario["id"]


def test_verificar_token_alterado(base, usuario):
    resp = requests.get(f"{base}/api/auth/verificar", headers={"Authorization": f"Bearer {usuario['token']}x"})
    assert resp.status_code == 401
    assert resp.json()["error"] == "Token inválido"


def test_cors_habilitado_para_el_frontend(base):
    resp = requests.options(f"{base}/api/vuelos", headers={"Origin": "http://192.168.1.50:8080",
                                                           "Access-Control-Request-Method": "GET"})
    assert resp.headers["Access-Control-Allow-Origin"] == "*"
    assert "Authorization" in resp.headers["Access-Control-Allow-Headers"]
