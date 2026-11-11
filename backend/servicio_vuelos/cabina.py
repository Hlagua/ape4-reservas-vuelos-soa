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
             "filas": len(c["filas"]), "configuracion": configuracion(c),
             "asientos": sum(1 for clase in self.asientos.values() if clase == c["clase"])}
            for c in self.clases]}


# Clases que puede tener un avión nuevo, en orden desde la parte delantera, con su factor de precio
CLASES_DISPONIBLES = {
    "FIRST": ("First", 6.0),
    "BUSINESS": ("Business", 3.5),
    "PREMIUM": ("Premium Economy", 1.6),
    "ECONOMY": ("Economy", 1.0),
}
LETRAS = "ABCDEFGHJKLMNOP"  # sin la I, como en las aerolíneas (se confunde con el 1)
MAX_ASIENTOS_AVION = 600


def construir_clases(definicion):
    """Arma la cabina de un avión nuevo.

    definicion: [{"clase": "ECONOMY", "filas": 25, "configuracion": "3-3"}, ...]
    La configuración son los asientos de cada bloque separados por pasillos ("2-4-2").
    Las filas se numeran seguidas desde la parte delantera. Devuelve (clases, errores).
    """
    errores = {}
    if not isinstance(definicion, list) or not definicion:
        return None, {"clases": "Agregue al menos una clase"}
    vistas, clases, fila_inicial = set(), [], 1
    por_orden = sorted((d for d in definicion if isinstance(d, dict)),
                       key=lambda d: list(CLASES_DISPONIBLES).index(d.get("clase"))
                       if d.get("clase") in CLASES_DISPONIBLES else 99)
    for i, d in enumerate(por_orden):
        clase = d.get("clase")
        if clase not in CLASES_DISPONIBLES:
            errores[f"clases[{i}].clase"] = f"Clase no válida. Opciones: {', '.join(CLASES_DISPONIBLES)}"
            continue
        if clase in vistas:
            errores[f"clases[{i}].clase"] = f"La clase {clase} está repetida"
            continue
        vistas.add(clase)
        try:
            filas = int(d.get("filas"))
            if not 1 <= filas <= 60:
                raise ValueError
        except (TypeError, ValueError):
            errores[f"clases[{i}].filas"] = "Las filas deben ser un número entre 1 y 60"
            continue
        try:
            bloques = [int(x) for x in str(d.get("configuracion", "")).strip().split("-")]
            if not 1 <= len(bloques) <= 4 or any(not 1 <= b <= 4 for b in bloques) or sum(bloques) > len(LETRAS):
                raise ValueError
        except ValueError:
            errores[f"clases[{i}].configuracion"] = "Use bloques de 1 a 4 asientos separados por guiones (ej. 3-3 o 2-4-2)"
            continue
        letras, grupos = iter(LETRAS), []
        for b in bloques:
            grupos.append([next(letras) for _ in range(b)])
        nombre, factor = CLASES_DISPONIBLES[clase]
        clases.append({"clase": clase, "nombre": nombre, "filas": list(range(fila_inicial, fila_inicial + filas)),
                       "grupos": grupos, "factor": factor})
        fila_inicial += filas
    if not errores:
        total = sum(len(c["filas"]) * sum(len(g) for g in c["grupos"]) for c in clases)
        if total > MAX_ASIENTOS_AVION:
            errores["clases"] = f"El avión tendría {total} asientos; el máximo es {MAX_ASIENTOS_AVION}"
    return (None, errores) if errores else (clases, {})


def configuracion(clase):
    """'3-3' a partir de los grupos de una clase."""
    return "-".join(str(len(g)) for g in clase["grupos"])


def _crear(avion, clases):
    return Cabina(avion, clases, {f"{fila}{letra}": c["clase"]
                                  for c in clases for fila in c["filas"] for grupo in c["grupos"] for letra in grupo})


CABINAS = {avion: _crear(avion, clases) for avion, clases in AVIONES.items()}


def crear_cabina(avion, clases):
    return _crear(avion, clases)


# Compatibilidad: datos de ejemplo (init_db) y pruebas usan el avión predeterminado
AVION = AVION_PREDETERMINADO
CLASES = AVIONES[AVION]
ASIENTOS = CABINAS[AVION].asientos
TOTAL_ASIENTOS = CABINAS[AVION].total
