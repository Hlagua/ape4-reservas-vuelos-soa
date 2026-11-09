"""Supervisor del backend: levanta el API Gateway y los 5 servicios, cada uno en su propio proceso.

Uso:  python run_backend.py      (Ctrl+C para detener todo)

- Cada servicio se ejecuta con waitress (servidor WSGI de producción, funciona en Windows y en Linux/Render).
- Si un servicio interno se cae, los demás SIGUEN funcionando (tolerancia a fallos de SOA).
- Si se cae el Gateway, el supervisor lo vuelve a levantar: es el único punto de entrada.
- Expone un control interno en 127.0.0.1:SUPERVISOR_PORT (solo lo usa el Gateway, con la clave
  de servicio) para detener e iniciar servicios durante las pruebas de tolerancia a fallos.
"""
import json
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from common import config

BASE_DIR = Path(__file__).resolve().parent
# clave: (nombre, módulo, host, puerto)
SERVICIOS = {
    "usuarios": ("Usuarios", "servicio_usuarios.app", config.BIND_HOST, config.USUARIOS_PORT),
    "auth": ("Autenticación", "servicio_auth.app", config.BIND_HOST, config.AUTH_PORT),
    "vuelos": ("Vuelos", "servicio_vuelos.app", config.BIND_HOST, config.VUELOS_PORT),
    "reservas": ("Reservas", "servicio_reservas.app", config.BIND_HOST, config.RESERVAS_PORT),
    "facturas": ("Facturación", "servicio_facturacion.app", config.BIND_HOST, config.FACTURACION_PORT),
    "gateway": ("API Gateway", "gateway.app", config.GATEWAY_HOST, config.GATEWAY_PORT),
}
INTERNOS = [c for c in SERVICIOS if c != "gateway"]


def ip_local():
    """IP de esta computadora en la red local (la que usará el cliente)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def esperar_puerto(puerto, segundos=180):
    """Espera hasta que un servicio acepte conexiones en 127.0.0.1:puerto."""
    limite = time.time() + segundos
    while time.time() < limite:
        try:
            with socket.create_connection(("127.0.0.1", puerto), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False


class Supervisor:
    def __init__(self):
        self.procesos = {}          # clave -> Popen
        self.detenidos = set()      # servicios apagados a propósito (no se reportan como caídas)
        self.bloqueo = threading.Lock()

    def iniciar(self, clave):
        nombre, modulo, host, puerto = SERVICIOS[clave]
        with self.bloqueo:
            proceso = self.procesos.get(clave)
            if proceso and proceso.poll() is None:
                return False
            self.procesos[clave] = subprocess.Popen(
                [sys.executable, "-m", "waitress", f"--host={host}", f"--port={puerto}", "--threads=8",
                 f"{modulo}:app"], cwd=BASE_DIR)
            self.detenidos.discard(clave)
        print(f"  [supervisor] {nombre:<15} iniciado en {host}:{puerto}", flush=True)
        return True

    def detener(self, clave):
        with self.bloqueo:
            proceso = self.procesos.get(clave)
            self.detenidos.add(clave)
            if not proceso or proceso.poll() is not None:
                return False
            proceso.terminate()
        proceso.wait(timeout=15)
        print(f"  [supervisor] {SERVICIOS[clave][0]:<15} DETENIDO a pedido", flush=True)
        return True

    def estado(self):
        with self.bloqueo:
            return {clave: {
                "nombre": SERVICIOS[clave][0],
                "puerto": SERVICIOS[clave][3],
                "proceso": "activo" if self.procesos.get(clave) and self.procesos[clave].poll() is None
                else ("detenido" if clave in self.detenidos else "caído"),
            } for clave in SERVICIOS}

    def vigilar(self):
        """Avisa si un servicio interno se cae solo y revive el Gateway si se cae."""
        reportados = set()
        while True:
            time.sleep(1)
            for clave, proceso in list(self.procesos.items()):
                if proceso.poll() is None or clave in self.detenidos:
                    reportados.discard(clave)
                    continue
                if clave == "gateway":
                    print("  [supervisor] El API Gateway se cayó: se reinicia", flush=True)
                    self.iniciar("gateway")
                elif clave not in reportados:
                    print(f"  [supervisor] {SERVICIOS[clave][0]} se cayó; los demás servicios siguen funcionando",
                          flush=True)
                    reportados.add(clave)

    def apagar_todo(self):
        for proceso in self.procesos.values():
            if proceso.poll() is None:
                proceso.terminate()
        for proceso in self.procesos.values():
            try:
                proceso.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proceso.kill()


def servidor_de_control(supervisor):
    """API interna del supervisor: GET /servicios, POST /servicios/<clave>/<detener|iniciar>."""

    class Manejador(BaseHTTPRequestHandler):
        def _responder(self, codigo, cuerpo):
            datos = json.dumps(cuerpo, ensure_ascii=False).encode()
            self.send_response(codigo)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(datos)))
            self.end_headers()
            self.wfile.write(datos)

        def _autorizado(self):
            if self.headers.get("X-Service-Key") != config.SERVICE_KEY:
                self._responder(403, {"error": "Acceso restringido"})
                return False
            return True

        def do_GET(self):
            if self._autorizado():
                self._responder(200, {"servicios": supervisor.estado()})

        def do_POST(self):
            if not self._autorizado():
                return
            partes = self.path.strip("/").split("/")
            if len(partes) != 3 or partes[0] != "servicios" or partes[2] not in ("detener", "iniciar"):
                return self._responder(404, {"error": "Ruta no encontrada"})
            clave, accion = partes[1], partes[2]
            if clave not in INTERNOS:
                return self._responder(400, {"error": f"Servicio inválido. Opciones: {', '.join(INTERNOS)}"})
            if accion == "detener":
                cambio = supervisor.detener(clave)
            else:
                cambio = supervisor.iniciar(clave)
                if cambio and not esperar_puerto(SERVICIOS[clave][3], 90):
                    return self._responder(504, {"error": "El servicio no terminó de arrancar"})
            nombre = SERVICIOS[clave][0]
            mensaje = (f"{nombre} {'detenido' if accion == 'detener' else 'iniciado'}" if cambio
                       else f"{nombre} ya estaba {'detenido' if accion == 'detener' else 'activo'}")
            self._responder(200, {"mensaje": mensaje, "servicios": supervisor.estado()})

        def log_message(self, *args):
            pass  # sin ruido en los logs

    servidor = ThreadingHTTPServer(("127.0.0.1", config.SUPERVISOR_PORT), Manejador)
    threading.Thread(target=servidor.serve_forever, daemon=True).start()


def main():
    supervisor = Supervisor()
    for clave in INTERNOS:
        supervisor.iniciar(clave)

    # El Gateway (puerto público) se abre recién cuando los servicios internos ya escuchan:
    # así Render no marca el servicio como disponible antes de tiempo
    for clave in INTERNOS:
        if not esperar_puerto(SERVICIOS[clave][3]):
            print(f"El servicio {SERVICIOS[clave][0]} no arrancó a tiempo", flush=True)
    servidor_de_control(supervisor)
    supervisor.iniciar("gateway")
    print(f"\nAPI Gateway para el cliente:  http://{ip_local()}:{config.GATEWAY_PORT}")
    print("Swagger de cada servicio:     http://<ip>:<puerto>/apidocs")
    print("Ctrl+C para detener todo\n", flush=True)

    # Render detiene el servicio con SIGTERM
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        supervisor.vigilar()
    except (KeyboardInterrupt, SystemExit):
        print("\nDeteniendo servicios...", flush=True)
    finally:
        supervisor.apagar_todo()


if __name__ == "__main__":
    main()
