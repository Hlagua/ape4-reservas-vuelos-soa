"""Configuración de cabina de cada tipo de avión: clases, filas y columnas.

Cada avión tiene su propia distribución y número de asientos; el vuelo guarda el nombre del avión
(columna `avion`) y con él se obtiene su cabina.
`grupos` son los bloques de asientos separados por pasillos.
`factor` multiplica el precio base del vuelo (precio de Economy).
"""
from dataclasses import dataclass, field


def _clase(clase, nombre, filas, grupos, factor):
    return {"clase": clase, "nombre": nombre, "filas": list(filas), "grupos": grupos, "factor": factor}


AVIONES = {
    # Fuselaje ancho, cuatro clases (el avión de los vuelos de ejemplo)
    "Airbus A340-600": [
        _clase("FIRST", "First", range(1, 3), [["A"], ["D", "G"], ["K"]], 6.0),
        _clase("BUSINESS", "Business", range(4, 9), [["A", "C"], ["D", "G"], ["H", "K"]], 3.5),
        _clase("PREMIUM", "Premium Economy", range(20, 24), [["A", "C"], ["D", "E", "F"], ["H", "K"]], 1.6),
        _clase("ECONOMY", "Economy", range(31, 51), [["A", "C"], ["D", "E", "F", "G"], ["H", "K"]], 1.0),
    ],
    # Fuselaje ancho, tres clases
    "Boeing 787-9": [
        _clase("BUSINESS", "Business", range(1, 8), [["A"], ["D", "G"], ["K"]], 3.5),
        _clase("PREMIUM", "Premium Economy", range(20, 25), [["A", "C"], ["D", "E", "F"], ["H", "K"]], 1.6),
        _clase("ECONOMY", "Economy", range(30, 51), [["A", "B", "C"], ["D", "E", "F"], ["H", "J", "K"]], 1.0),
    ],
    # Fuselaje angosto, un pasillo
    "Airbus A320": [
        _clase("BUSINESS", "Business", range(1, 4), [["A", "C"], ["D", "F"]], 3.0),
        _clase("ECONOMY", "Economy", range(6, 31), [["A", "B", "C"], ["D", "E", "F"]], 1.0),
    ],
    # Regional
    "Embraer E190": [
        _clase("BUSINESS", "Business", range(1, 4), [["A"], ["C", "D"]], 2.5),
        _clase("ECONOMY", "Economy", range(5, 27), [["A", "B"], ["C", "D"]], 1.0),
    ],
    # Turbohélice regional, solo Economy
    "ATR 72-600": [
        _clase("ECONOMY", "Economy", range(1, 19), [["A", "B"], ["C", "D"]], 1.0),
    ],
}
AVION_PREDETERMINADO = "Airbus A340-600"


@dataclass(frozen=True)
class Cabina:
    avion: str
    clases: list
    asientos: dict = field(default_factory=dict)  # "31A" -> "ECONOMY"

    @property
    def total(self):
        return len(self.asientos)

    def precio(self, precio_base, asiento):
        factor = next(c["factor"] for c in self.clases if c["clase"] == self.asientos[asiento])
        return round(float(precio_base) * factor, 2)

    def resumen(self):
        return {"avion": self.avion, "total_asientos": self.total, "clases": [
            {"clase": c["clase"], "nombre": c["nombre"], "factor": c["factor"],
             "asientos": sum(1 for clase in self.asientos.values() if clase == c["clase"])}
            for c in self.clases]}


def _crear(avion, clases):
    return Cabina(avion, clases, {f"{fila}{letra}": c["clase"]
                                  for c in clases for fila in c["filas"] for grupo in c["grupos"] for letra in grupo})


CABINAS = {avion: _crear(avion, clases) for avion, clases in AVIONES.items()}


def cabina(avion):
    """Cabina del avión del vuelo (los vuelos antiguos sin tipo conocido usan el avión predeterminado)."""
    return CABINAS.get(avion) or CABINAS[AVION_PREDETERMINADO]


# Compatibilidad: datos de ejemplo (init_db) y pruebas usan el avión predeterminado
AVION = AVION_PREDETERMINADO
CLASES = AVIONES[AVION]
ASIENTOS = CABINAS[AVION].asientos
TOTAL_ASIENTOS = CABINAS[AVION].total
