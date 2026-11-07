// Reglas de validación de campos (las mismas que aplica el backend en common/validaciones.py)

const LIMITES = { nombre: 60, email: 50, passwordMin: 8, passwordMax: 64, asientos: 5 };
const LETRAS = "A-Za-zÁÉÍÓÚÜÑáéíóúüñ";

const Validar = {
  NOMBRE_RE: new RegExp(`^[${LETRAS}]+( [${LETRAS}]+)*$`),
  EMAIL_RE: /^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/,
  PASAPORTE_RE: /^[A-Z0-9]{6,9}$/,

  nombre(valor) {
    if (!valor) return "El nombre es obligatorio";
    if (valor.length < 3 || valor.length > LIMITES.nombre) return `Debe tener entre 3 y ${LIMITES.nombre} caracteres`;
    if (!this.NOMBRE_RE.test(valor)) return "Solo letras y un espacio entre palabras";
    return "";
  },

  email(valor) {
    if (!valor) return "El email es obligatorio";
    if (valor.length > LIMITES.email) return `Máximo ${LIMITES.email} caracteres`;
    if (/\s/.test(valor)) return "No se permiten espacios";
    if (valor !== valor.toLowerCase()) return "No se permiten letras mayúsculas";
    if (!this.EMAIL_RE.test(valor) || valor.includes("..") || valor.startsWith(".") || valor.includes(".@")) {
      return "Formato de email inválido (ejemplo: nombre@uta.edu.ec)";
    }
    return "";
  },

  password(valor) {
    if (!valor) return "La contraseña es obligatoria";
    if (/\s/.test(valor)) return "La contraseña no puede contener espacios";
    if (valor.length < LIMITES.passwordMin || valor.length > LIMITES.passwordMax) {
      return `Debe tener entre ${LIMITES.passwordMin} y ${LIMITES.passwordMax} caracteres`;
    }
    if (!/[A-Za-z]/.test(valor) || !/\d/.test(valor)) return "Debe contener al menos una letra y un número";
    return "";
  },

  // Algoritmo módulo 10 de la cédula ecuatoriana
  cedula(cedula) {
    if (!/^\d{10}$/.test(cedula)) return false;
    const provincia = Number(cedula.slice(0, 2));
    if (!((provincia >= 1 && provincia <= 24) || provincia === 30) || Number(cedula[2]) >= 6) return false;
    let suma = 0;
    for (let i = 0; i < 9; i++) {
      const valor = Number(cedula[i]) * (i % 2 === 0 ? 2 : 1);
      suma += valor > 9 ? valor - 9 : valor;
    }
    return (10 - (suma % 10)) % 10 === Number(cedula[9]);
  },

  documento(tipo, numero) {
    if (!numero) return "El documento es obligatorio";
    if (tipo === "CEDULA") return this.cedula(numero) ? "" : "Cédula ecuatoriana inválida (10 dígitos)";
    if (tipo === "PASAPORTE") return this.PASAPORTE_RE.test(numero) ? "" : "De 6 a 9 letras mayúsculas o números";
    return "Seleccione el tipo de documento";
  },
};

// Filtros de escritura: limpian lo que el usuario teclea o pega, antes de validar
const Filtro = {
  // Solo minúsculas, números y . _ % + - @ ; sin espacios en ninguna parte
  email: (v) => v.toLowerCase().replace(/[^a-z0-9._%+@-]/g, "").slice(0, LIMITES.email),
  // Solo letras; sin espacio al inicio ni espacios dobles
  nombre: (v) => v.replace(new RegExp(`[^${LETRAS} ]`, "g"), "").replace(/^ +/, "").replace(/ {2,}/g, " ")
    .slice(0, LIMITES.nombre),
  password: (v) => v.replace(/\s/g, "").slice(0, LIMITES.passwordMax),
  cedula: (v) => v.replace(/\D/g, "").slice(0, 10),
  pasaporte: (v) => v.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 9),
};

// Aplica un filtro a un input conservando la posición del cursor
function filtrarCampo(input, filtro) {
  const antes = input.value;
  const limpio = filtro(antes);
  if (limpio === antes) return;
  const cursor = Math.max(0, (input.selectionStart ?? limpio.length) - (antes.length - limpio.length));
  input.value = limpio;
  try { input.setSelectionRange(cursor, cursor); } catch { /* inputs sin selección (email) */ }
}

// Al salir del campo: quita espacios del final y pone mayúscula inicial en cada palabra
const formatearNombre = (texto) => texto.trim().toLowerCase().replace(/(^|\s)(\S)/g, (_, e, l) => e + l.toUpperCase());

// Muestra u oculta el mensaje de error debajo de un campo
function marcarCampo(input, mensaje) {
  const campo = input.closest(".campo");
  const salida = campo && campo.querySelector(".error-campo");
  input.classList.toggle("invalido", Boolean(mensaje));
  input.setAttribute("aria-invalid", mensaje ? "true" : "false");
  if (salida) salida.textContent = mensaje || "";
  return !mensaje;
}

// Normaliza espacios en un texto de nombre
const limpiarNombre = (texto) => texto.replace(/\s+/g, " ").trim();
