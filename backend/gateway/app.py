"""API Gateway: punto único de entrada para los clientes (frontend).

Enruta cada petición /api/<servicio>/... al servicio proveedor correspondiente
(Usuarios, Auth, Vuelos, Reservas, Facturación). Habilita CORS para que el frontend pueda
ejecutarse en otra computadora.
"""
import hmac
from concurrent.futures import ThreadPoolExecutor

from flask import Flask, Response, jsonify, request

from common import config
from common.clientes import llamar_servicio
from common.errores import ErrorApi, registrar_manejadores

app = Flask(__name__)
app.json.ensure_ascii = False
app.json.sort_keys = False
registrar_manejadores(app)

# Tabla de enrutamiento: prefijo de la ruta -> servicio proveedor
RUTAS = {
    "usuarios": (config.USUARIOS_URL, config.USUARIOS_PORT),
    "auth": (config.AUTH_URL, config.AUTH_PORT),
    "vuelos": (config.VUELOS_URL, config.VUELOS_PORT),
    "reservas": (config.RESERVAS_URL, config.RESERVAS_PORT),
    "facturas": (config.FACTURACION_URL, config.FACTURACION_PORT),
}
# Cabeceras que el cliente puede reenviar (X-Service-Key nunca pasa por el gateway)
CABECERAS_PERMITIDAS = {"authorization", "content-type", "accept"}


@app.after_request
def cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-Admin-Key"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    return resp


@app.get("/")
def inicio():
    return jsonify({"servicio": "API Gateway", "rutas": [f"/api/{r}" for r in RUTAS], "salud": "/api/salud"})


@app.get("/api/salud")
def salud():
    """Consulta en paralelo el estado de todos los servicios y de la base de datos."""
    def consultar(item):
        nombre, (url, puerto) = item
        try:
            resp = llamar_servicio("GET", f"{url}/api/salud")
            datos = resp.json() if resp.ok else {}
            return nombre, {"puerto": puerto, "estado": "activo" if resp.ok else "error",
                            "base_datos": datos.get("base_datos")}
        except ErrorApi:
            return nombre, {"puerto": puerto, "estado": "caído", "base_datos": None}

    with ThreadPoolExecutor(max_workers=len(RUTAS)) as hilos:
        estado = dict(hilos.map(consultar, RUTAS.items()))
    # La base es compartida: basta con que un servicio pueda conectarse para saber que responde
    reportes = [s.pop("base_datos") for s in estado.values()]
    base = "activa" if "activa" in reportes else ("caída" if "caída" in reportes else "desconocido")
    return jsonify({"gateway": "activo", "base_datos": base, "servicios": estado})


# ---------- Administración: pruebas de tolerancia a fallos ----------

def requerir_admin():
    if not config.ADMIN_KEY:
        raise ErrorApi("La administración está deshabilitada (falta ADMIN_KEY)", 403)
    if not hmac.compare_digest(request.headers.get("X-Admin-Key", ""), config.ADMIN_KEY):
        raise ErrorApi("Clave de administración inválida", 403)


def supervisor(metodo, ruta):
    """Reenvía la orden al supervisor (run_backend.py), que solo escucha en 127.0.0.1."""
    resp = llamar_servicio(metodo, f"{config.SUPERVISOR_URL}{ruta}", interno=True)
    return Response(resp.content, status=resp.status_code, content_type="application/json")


@app.get("/api/admin/servicios")
def admin_estado():
    """Estado de los procesos de cada servicio (requiere X-Admin-Key)."""
    requerir_admin()
    return supervisor("GET", "/servicios")


@app.post("/api/admin/servicios/<clave>/<accion>")
def admin_controlar(clave, accion):
    """Detiene o inicia un servicio interno para probar la tolerancia a fallos (requiere X-Admin-Key)."""
    requerir_admin()
    if accion not in ("detener", "iniciar"):
        raise ErrorApi("La acción debe ser 'detener' o 'iniciar'", 400)
    return supervisor("POST", f"/servicios/{clave}/{accion}")


@app.route("/api/<servicio>", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
@app.route("/api/<servicio>/<path:resto>", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
def enrutar(servicio, resto=""):
    if request.method == "OPTIONS":
        return Response(status=200)
    if servicio not in RUTAS:
        raise ErrorApi(f"No existe el servicio '{servicio}'", 404)
    url = f"{RUTAS[servicio][0]}/api/{servicio}" + (f"/{resto}" if resto else "")
    headers = {k: v for k, v in request.headers.items() if k.lower() in CABECERAS_PERMITIDAS}
    resp = llamar_servicio(request.method, url, params=request.args, data=request.get_data(), headers=headers)
    return Response(resp.content, status=resp.status_code,
                    content_type=resp.headers.get("Content-Type", "application/json"))


if __name__ == "__main__":
    app.run(host=config.GATEWAY_HOST, port=config.GATEWAY_PORT, threaded=True)
