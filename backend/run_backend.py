"""Levanta el backend completo: API Gateway + 5 servicios, cada uno en su propio proceso.

Uso:  python run_backend.py      (Ctrl+C para detener todo)

Cada servicio se ejecuta con waitress (servidor WSGI de producción, funciona en Windows y en Linux/Render).
"""
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from common import config

BASE_DIR = Path(__file__).resolve().parent
SERVICIOS = [
    ("Usuarios", "servicio_usuarios.app", config.BIND_HOST, config.USUARIOS_PORT),
    ("Autenticación", "servicio_auth.app", config.BIND_HOST, config.AUTH_PORT),
    ("Vuelos", "servicio_vuelos.app", config.BIND_HOST, config.VUELOS_PORT),
    ("Reservas", "servicio_reservas.app", config.BIND_HOST, config.RESERVAS_PORT),
    ("Facturación", "servicio_facturacion.app", config.BIND_HOST, config.FACTURACION_PORT),
    ("API Gateway", "gateway.app", config.GATEWAY_HOST, config.GATEWAY_PORT),
]


def ip_local():
    """IP de esta computadora en la red local (la que usará el cliente)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def comando(modulo, host, puerto):
    return [sys.executable, "-m", "waitress", f"--host={host}", f"--port={puerto}", "--threads=8", f"{modulo}:app"]


def main():
    procesos = []
    for nombre, modulo, host, puerto in SERVICIOS:
        procesos.append(subprocess.Popen(comando(modulo, host, puerto), cwd=BASE_DIR))
        print(f"  {nombre:<15} {host}:{puerto}", flush=True)
    print(f"\nAPI Gateway para el cliente:  http://{ip_local()}:{config.GATEWAY_PORT}")
    print("Swagger de cada servicio:     http://<ip>:<puerto>/apidocs")
    print("Ctrl+C para detener\n", flush=True)

    # Render detiene el servicio con SIGTERM: se reenvía a todos los procesos
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        while all(p.poll() is None for p in procesos):
            time.sleep(1)
        print("Un servicio se detuvo, cerrando el resto...")
    except (KeyboardInterrupt, SystemExit):
        print("\nDeteniendo servicios...")
    finally:
        for p in procesos:
            p.terminate()
        for p in procesos:
            p.wait()
    sys.exit(1 if any(p.returncode not in (0, -15, 1) for p in procesos) else 0)


if __name__ == "__main__":
    main()
