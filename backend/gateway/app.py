"""API Gateway: punto único de entrada para los clientes (frontend).

Enruta cada petición /api/<servicio>/... al servicio proveedor correspondiente
(Usuarios, Auth, Vuelos, Reservas, Facturación). Habilita CORS para que el frontend pueda
ejecutarse en otra computadora.
"""
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
    resp.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    return resp


@app.get("/")
def inicio():
    return jsonify({"servicio": "API Gateway", "rutas": [f"/api/{r}" for r in RUTAS], "salud": "/api/salud"})


@app.get("/api/salud")
def salud():
    """Consulta el estado de todos los servicios."""
    estado = {}
    for nombre, (url, puerto) in RUTAS.items():
        try:
            resp = llamar_servicio("GET", f"{url}/api/salud")
            estado[nombre] = {"puerto": puerto, "estado": "activo" if resp.ok else "error"}
        except ErrorApi:
            estado[nombre] = {"puerto": puerto, "estado": "caído"}
    return jsonify({"gateway": "activo", "servicios": estado})


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
