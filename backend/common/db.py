"""Conexión a PostgreSQL (Supabase) mediante SQLAlchemy + psycopg.

Se recomienda el "Transaction pooler" de Supabase (puerto 6543): admite muchas conexiones
simultáneas, a diferencia del "Session pooler" del plan gratuito (máximo 15).
"""
from sqlalchemy import create_engine, event
from sqlalchemy.engine import make_url

from common import config


def crear_engine(**kwargs):
    if not config.DATABASE_URL:
        raise RuntimeError("Falta DATABASE_URL en backend/.env (cadena de conexión de Supabase)")
    url = make_url(config.DATABASE_URL).set(drivername="postgresql+psycopg")
    # El pooler de Supabase en modo transacción no admite sentencias preparadas
    # connect_timeout: si la base no responde, se falla en 5 s en vez de dejar la petición colgada
    connect_args = {"prepare_threshold": None, "connect_timeout": 5}
    if url.host not in (None, "localhost", "127.0.0.1"):
        connect_args["sslmode"] = "require"  # Supabase exige conexión cifrada (SSL)
    # Se reciclan las conexiones cada 5 min en vez de verificarlas antes de cada uso (ahorra un viaje a la base)
    nuevo = create_engine(url, pool_recycle=300, pool_size=5, max_overflow=5, pool_timeout=10,
                          connect_args=connect_args, **kwargs)

    @event.listens_for(nuevo, "begin")
    def _zona_horaria(conexion):
        # Cada transacción trabaja en hora de Ecuador (LOCALTIMESTAMP, CURRENT_DATE).
        # SET LOCAL funciona también con el pooler en modo transacción.
        conexion.exec_driver_sql(f"SET LOCAL TIME ZONE '{config.ZONA_HORARIA_BD}'")

    return nuevo


engine = crear_engine()
