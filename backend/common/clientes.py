"""Utilidades para que un servicio consuma a otro (comunicación HTTP/JSON)."""
import requests
from requests.adapters import HTTPAdapter
from flask import request

from common import config
from common.errores import ErrorApi

TIMEOUT = 15

# Sesión HTTP compartida con pool de conexiones Keep-Alive para alta concurrencia
_session = requests.Session()
_adapter = HTTPAdapter(pool_connections=50, pool_maxsize=50, max_retries=1)
_session.mount("http://", _adapter)
_session.mount("https://", _adapter)


def llamar_servicio(metodo, url, interno=False, **kwargs):
    """Hace una petición HTTP a otro servicio y devuelve la respuesta.

    Si el servicio no responde se lanza un 503 controlado.
    `interno=True` agrega la clave de servicio para endpoints internos.
    """
    headers = kwargs.pop("headers", {}) or {}
    if interno:
        headers["X-Service-Key"] = config.SERVICE_KEY
    try:
        return _session.request(metodo, url, headers=headers, timeout=TIMEOUT, **kwargs)
    except requests.RequestException as e:
        raise ErrorApi("Servicio no disponible", 503, f"No se pudo contactar {url}: {e.__class__.__name__}")


def requerir_token():
    """Valida el token Bearer consultando al servicio de Autenticación.

    Devuelve los datos del usuario autenticado: {id, nombre, email}.
    """
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise ErrorApi("No autorizado. Token inválido o no enviado", 401)
    resp = llamar_servicio("GET", f"{config.AUTH_URL}/api/auth/verificar", headers={"Authorization": auth})
    if resp.status_code != 200:
        raise ErrorApi("No autorizado. Token inválido o expirado", 401)
    return resp.json()["usuario"]


def usuario_opcional():
    """Como requerir_token, pero devuelve None si no se envió token."""
    if not request.headers.get("Authorization"):
        return None
    return requerir_token()


def requerir_clave_servicio():
    """Protege endpoints internos: solo otros servicios conocen la clave."""
    if request.headers.get("X-Service-Key") != config.SERVICE_KEY:
        raise ErrorApi("Acceso restringido a servicios internos", 403)
