"""Servicio de Autenticación (proveedor y consumidor).

Emite, verifica y revoca tokens JWT. Para el login consume al servicio de Usuarios.
Es dueño del esquema `autenticacion`: cada token emitido se registra en la tabla
`tokens`, lo que permite cerrar sesión (revocarlo) antes de que expire.
"""
import hashlib
import uuid
from datetime import datetime, timedelta, timezone

import jwt
from flask import jsonify, request
from sqlalchemy import text

from common import config
from common.app_base import crear_app
from common.clientes import llamar_servicio
from common.db import engine
from common.errores import ErrorApi, leer_json
from common.validaciones import EMAIL_MAX, PASSWORD_MAX

app = crear_app(__name__, "Autenticación", "Inicio de sesión, verificación y cierre de sesión con tokens JWT")


def huella(token):
    """En la base se guarda el SHA-256 del token, no el token completo."""
    return hashlib.sha256(token.encode()).hexdigest()


def token_del_encabezado():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise ErrorApi("No autorizado. Token inválido o no enviado", 401)
    return auth[7:]


def validar_token(token):
    """Comprueba firma, expiración y que el token siga ACTIVO en la tabla tokens."""
    try:
        datos = jwt.decode(token, config.JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise ErrorApi("Token expirado", 401)
    except jwt.InvalidTokenError:
        raise ErrorApi("Token inválido", 401)
    with engine.connect() as con:
        registro = con.execute(text("""
            SELECT estado FROM autenticacion.tokens
            WHERE jti = :jti AND token_hash = :hash AND expiracion > LOCALTIMESTAMP
        """), {"jti": datos.get("jti"), "hash": huella(token)}).first()
    if not registro:
        raise ErrorApi("Token inválido", 401)
    if registro.estado != "ACTIVO":
        raise ErrorApi("La sesión fue cerrada, vuelva a iniciar sesión", 401)
    return datos


@app.post("/api/auth/login")
def login():
    """Iniciar sesión y obtener un token JWT
    ---
    tags: [Autenticación]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [email, password]
          properties:
            email: {type: string, example: juan@uta.edu.ec}
            password: {type: string, example: secreto123}
    responses:
      200: {description: Login correcto, devuelve el token}
      400: {description: Faltan datos}
      401: {description: Credenciales inválidas}
      503: {description: Servicio de Usuarios no disponible}
    """
    data = leer_json(request)
    if not data.get("email") or not data.get("password"):
        raise ErrorApi("Email y contraseña son obligatorios", 400)
    if len(str(data["email"])) > EMAIL_MAX or len(str(data["password"])) > PASSWORD_MAX:
        raise ErrorApi("Email o contraseña demasiado largos", 400)

    # Consumo del servicio de Usuarios (comunicación entre servicios)
    resp = llamar_servicio("POST", f"{config.USUARIOS_URL}/api/usuarios/validar-credenciales",
                           interno=True, json={"email": data["email"], "password": data["password"]})
    if resp.status_code == 401:
        raise ErrorApi("Credenciales inválidas", 401)
    if resp.status_code != 200:
        raise ErrorApi("No se pudo validar el usuario", 502, resp.json())

    usuario = resp.json()
    expira = config.ahora() + timedelta(hours=config.JWT_HORAS)
    jti = str(uuid.uuid4())
    token = jwt.encode({
        "sub": str(usuario["id"]),
        "nombre": usuario["nombre"],
        "email": usuario["email"],
        "jti": jti,
        "exp": datetime.now(timezone.utc) + timedelta(hours=config.JWT_HORAS),  # el estándar JWT usa UTC
    }, config.JWT_SECRET, algorithm="HS256")

    with engine.begin() as con:
        con.execute(text("""
            INSERT INTO autenticacion.tokens (usuario_id, jti, token_hash, expiracion)
            VALUES (:u, :jti, :hash, :exp)
        """), {"u": usuario["id"], "jti": jti, "hash": huella(token), "exp": expira})

    return jsonify({
        "mensaje": "Inicio de sesión exitoso",
        "token": token,
        "tipo": "Bearer",
        "expira": expira.isoformat(timespec="seconds"),
        "usuario": {"id": usuario["id"], "nombre": usuario["nombre"], "email": usuario["email"]},
    })


@app.get("/api/auth/verificar")
def verificar():
    """Verificar un token JWT (lo usan los demás servicios)
    ---
    tags: [Autenticación]
    security: [{Bearer: []}]
    responses:
      200: {description: Token válido, devuelve el usuario}
      401: {description: Token inválido, expirado, revocado o ausente}
    """
    datos = validar_token(token_del_encabezado())
    return jsonify({
        "valido": True,
        "usuario": {"id": int(datos["sub"]), "nombre": datos["nombre"], "email": datos["email"]},
    })


@app.post("/api/auth/logout")
def logout():
    """Cerrar sesión: el token queda REVOCADO y ya no sirve en ningún servicio
    ---
    tags: [Autenticación]
    security: [{Bearer: []}]
    responses:
      200: {description: Sesión cerrada}
      401: {description: Token inválido, expirado o ya revocado}
    """
    token = token_del_encabezado()
    datos = validar_token(token)
    with engine.begin() as con:
        con.execute(text("UPDATE autenticacion.tokens SET estado = 'REVOCADO' WHERE jti = :jti"),
                    {"jti": datos["jti"]})
    return jsonify({"mensaje": "Sesión cerrada correctamente"})


if __name__ == "__main__":
    app.run(host=config.BIND_HOST, port=config.AUTH_PORT, threaded=True)
