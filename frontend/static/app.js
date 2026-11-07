// Cliente web: consume el backend a través del API Gateway (HTTP + JSON)

const API = (window.APP_CONFIG && window.APP_CONFIG.apiUrl) || "http://127.0.0.1:5000";
const INTERVALO_ACTUALIZACION = 3000; // ms entre consultas del mapa de asientos

const estado = {
  token: leerLocal("token"),
  usuario: JSON.parse(leerLocal("usuario") || "null"),
  pendiente: null, // a dónde volver después de iniciar sesión
};

// Estado de la vista de asientos
const mapa = {
  vueloId: null,
  datos: null,
  claseActiva: null,
  claseDe: {},          // asiento -> clase
  precioClase: {},      // clase -> precio
  edicion: null,        // {reservaId, quitados: Set} cuando se modifica una reserva
  expiran: {},          // asiento retenido -> timestamp de expiración
  pasajeros: {},        // asiento -> {nombre, tipo_documento, documento}
  liberadosPorMi: new Set(),
  claveSeleccion: "",
  temporizador: null,
  reloj: null,
  cargando: false,
};

function leerLocal(clave) {
  try { return localStorage.getItem(clave); } catch { return null; }
}
function guardarLocal(clave, valor) {
  try { valor === null ? localStorage.removeItem(clave) : localStorage.setItem(clave, valor); } catch { /* sin almacenamiento */ }
}

// ---------- Utilidades ----------

class ErrorApi extends Error {
  constructor(status, datos) {
    super(datos.error || "Error");
    this.status = status;
    this.datos = datos;
  }
}

async function api(metodo, ruta, cuerpo) {
  const opciones = { method: metodo, headers: {} };
  if (estado.token) opciones.headers.Authorization = `Bearer ${estado.token}`;
  if (cuerpo) {
    opciones.headers["Content-Type"] = "application/json";
    opciones.body = JSON.stringify(cuerpo);
  }
  let resp;
  try {
    resp = await fetch(API + ruta, opciones);
  } catch {
    throw new ErrorApi(0, { error: `No se puede conectar con el backend (${API})` });
  }
  const datos = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    if (resp.status === 401 && estado.token && ruta !== "/api/auth/login") cerrarSesion(false);
    throw new ErrorApi(resp.status, datos);
  }
  return datos;
}

function textoError(err) {
  const d = err.datos && err.datos.detalle;
  if (d && typeof d === "object" && !Array.isArray(d)) {
    return `${err.message}: ${Object.values(d).flat().join(", ")}`;
  }
  return err.message;
}

function avisar(texto, tipo = "ok") {
  const div = document.createElement("div");
  div.className = `aviso ${tipo}`;
  div.textContent = texto;
  document.getElementById("avisos").appendChild(div);
  setTimeout(() => div.remove(), 5000);
}

const $ = (id) => document.getElementById(id);
const dinero = (n) => `$${Number(n).toFixed(2)}`;
const fechaHora = (iso) => iso.replace("T", " ").slice(0, 16);
const hora = (iso) => iso.slice(11, 16);
const escapar = (t) => String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const hoyISO = () => {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
};

function duracion(salida, llegada) {
  const min = Math.round((new Date(llegada) - new Date(salida)) / 60000);
  return `${Math.floor(min / 60)}h ${String(min % 60).padStart(2, "0")}m`;
}

function confirmar({ titulo, html, textoOk = "Confirmar", soloCerrar = false }) {
  return new Promise((resolver) => {
    $("mensaje-titulo").textContent = titulo;
    $("mensaje-cuerpo").innerHTML = html;
    $("mensaje-ok").textContent = textoOk;
    $("mensaje-ok").classList.toggle("oculta", soloCerrar);
    $("mensaje-cancelar").textContent = soloCerrar ? "Cerrar" : "Cancelar";
    const d = $("modal-mensaje");
    d.onclose = () => resolver(d.returnValue === "ok");
    d.returnValue = "";
    d.showModal();
  });
}

// ---------- Navegación y sesión ----------

function mostrarVista(nombre) {
  if (["reservas"].includes(nombre) && !estado.token) {
    estado.pendiente = { vista: nombre };
    nombre = "acceso";
  }
  if (nombre !== "asientos") salirDelMapa();
  document.querySelectorAll(".vista").forEach((v) => v.classList.add("oculta"));
  $(`vista-${nombre}`).classList.remove("oculta");
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("activa", t.dataset.vista === nombre));
  if (nombre === "reservas") cargarReservas();
  if (nombre === "estado") cargarEstado();
  if (nombre === "acceso") $("login-email").focus();
  window.scrollTo(0, 0);
}

function pintarSesion() {
  const caja = $("sesion");
  caja.innerHTML = "";
  if (estado.usuario) {
    const nombre = document.createElement("span");
    nombre.textContent = `Hola, ${estado.usuario.nombre}`;
    const salir = document.createElement("button");
    salir.textContent = "Salir";
    salir.className = "mini secundario";
    salir.onclick = () => cerrarSesion(true);
    caja.append(nombre, salir);
  } else {
    const entrar = document.createElement("button");
    entrar.textContent = "Iniciar sesión";
    entrar.className = "mini secundario";
    entrar.onclick = () => mostrarVista("acceso");
    caja.append(entrar);
  }
}

function cerrarSesion(manual) {
  salirDelMapa();
  estado.token = null;
  estado.usuario = null;
  guardarLocal("token", null);
  guardarLocal("usuario", null);
  pintarSesion();
  if (!manual) avisar("La sesión expiró, vuelva a ingresar", "error");
  mostrarVista(manual ? "vuelos" : "acceso");
}

// ---------- Login ----------

// Evita doble envío: deshabilita el botón mientras dura la petición
async function conBotonOcupado(boton, accion) {
  if (boton.disabled) return;
  const texto = boton.textContent;
  boton.disabled = true;
  boton.textContent = "Procesando...";
  try { await accion(); } finally {
    boton.disabled = false;
    boton.textContent = texto;
  }
}

// Casillas "Mostrar contraseña"
document.querySelectorAll("[data-ver]").forEach((casilla) => casilla.addEventListener("change", () => {
  casilla.dataset.ver.split(" ").forEach((id) => { $(id).type = casilla.checked ? "text" : "password"; });
}));

// Contadores de caracteres (ej. 12/50)
function actualizarContadores() {
  document.querySelectorAll(".contador").forEach((c) => {
    const input = $(c.dataset.de);
    c.textContent = `${input.value.length}/${input.maxLength}`;
  });
}

$("form-login").email.addEventListener("input", (e) => filtrarCampo(e.target, Filtro.email));
$("form-login").password.addEventListener("input", (e) => filtrarCampo(e.target, Filtro.password));

$("form-login").addEventListener("submit", (e) => {
  e.preventDefault();
  const f = e.target;
  const okEmail = marcarCampo(f.email, Validar.email(f.email.value));
  const okPass = marcarCampo(f.password, f.password.value ? "" : "La contraseña es obligatoria");
  if (!okEmail || !okPass) return;
  conBotonOcupado(f.querySelector("[type=submit]"), () => iniciarSesion(f));
});

async function iniciarSesion(f) {
  try {
    const r = await api("POST", "/api/auth/login", { email: f.email.value, password: f.password.value });
    estado.token = r.token;
    estado.usuario = r.usuario;
    guardarLocal("token", r.token);
    guardarLocal("usuario", JSON.stringify(r.usuario));
    f.reset();
    pintarSesion();
    avisar(r.mensaje);
    const pendiente = estado.pendiente;
    estado.pendiente = null;
    if (pendiente && pendiente.vista === "asientos") abrirMapa(pendiente.vueloId);
    else mostrarVista(pendiente ? pendiente.vista : "vuelos");
  } catch (err) {
    marcarCampo(f.password, err.status === 401 ? "Email o contraseña incorrectos" : "");
    if (err.status !== 401) avisar(textoError(err), "error");
  }
}
["email", "password"].forEach((n) => $("form-login")[n].addEventListener("input", (e) => marcarCampo(e.target, "")));

// ---------- Registro (modal) ----------

const formRegistro = $("form-registro");
const reglasRegistro = {
  nombre: (f) => Validar.nombre(f.nombre.value.trim()),
  email: (f) => Validar.email(f.email.value),
  password: (f) => Validar.password(f.password.value),
  confirmar: (f) => (!f.confirmar.value ? "Confirme la contraseña"
    : f.confirmar.value !== f.password.value ? "Las contraseñas no coinciden" : ""),
};

$("abrir-registro").addEventListener("click", () => {
  formRegistro.reset();
  formRegistro.querySelectorAll("input").forEach((i) => marcarCampo(i, ""));
  formRegistro.password.type = formRegistro.confirmar.type = "password";
  actualizarContadores();
  $("modal-registro").showModal();
  formRegistro.nombre.focus();
});
formRegistro.querySelector("[data-cerrar]").addEventListener("click", () => $("modal-registro").close());

Object.keys(reglasRegistro).forEach((campo) => {
  const input = formRegistro[campo];
  input.addEventListener("blur", () => input.value && marcarCampo(input, reglasRegistro[campo](formRegistro)));
  input.addEventListener("input", () => {
    if (input.classList.contains("invalido")) marcarCampo(input, reglasRegistro[campo](formRegistro));
  });
});
// Filtros de escritura: lo que no está permitido no se puede teclear ni pegar
const filtrosRegistro = { nombre: Filtro.nombre, email: Filtro.email, password: Filtro.password, confirmar: Filtro.password };
Object.entries(filtrosRegistro).forEach(([campo, filtro]) => {
  formRegistro[campo].addEventListener("input", (e) => { filtrarCampo(e.target, filtro); actualizarContadores(); });
});
formRegistro.nombre.addEventListener("blur", (e) => { e.target.value = formatearNombre(e.target.value); actualizarContadores(); });
// La confirmación debe escribirse, no pegarse
formRegistro.confirmar.addEventListener("paste", (e) => {
  e.preventDefault();
  marcarCampo(formRegistro.confirmar, "Escriba nuevamente la contraseña (no se permite pegar)");
});

formRegistro.addEventListener("submit", (e) => {
  e.preventDefault();
  formRegistro.nombre.value = formatearNombre(formRegistro.nombre.value);
  const valido = Object.keys(reglasRegistro)
    .map((c) => marcarCampo(formRegistro[c], reglasRegistro[c](formRegistro)))
    .every(Boolean);
  if (!valido) { formRegistro.querySelector(".invalido")?.focus(); return; }
  conBotonOcupado(formRegistro.querySelector("[type=submit]"), registrarUsuario);
});

async function registrarUsuario() {
  try {
    const r = await api("POST", "/api/usuarios", {
      nombre: formRegistro.nombre.value,
      email: formRegistro.email.value,
      password: formRegistro.password.value,
    });
    $("modal-registro").close();
    $("form-login").email.value = r.usuario.email;
    $("form-login").password.focus();
    avisar(`${r.mensaje}. Ya puede iniciar sesión.`);
  } catch (err) {
    if (err.status === 409) marcarCampo(formRegistro.email, "Este email ya está registrado");
    else if (err.status === 400 && err.datos.detalle) {
      Object.entries(err.datos.detalle).forEach(([c, m]) => formRegistro[c] && marcarCampo(formRegistro[c], m));
    } else avisar(textoError(err), "error");
  }
}

// ---------- Búsqueda de vuelos ----------

const formBusqueda = $("form-busqueda");
formBusqueda.fecha.min = hoyISO();
formBusqueda.fecha.max = `${Number(hoyISO().slice(0, 4)) + 1}${hoyISO().slice(4)}`; // hasta un año

// El destino no puede ser la misma ciudad que el origen
formBusqueda.origen.addEventListener("change", () => {
  [...formBusqueda.destino.options].forEach((o) => { o.disabled = Boolean(o.value) && o.value === formBusqueda.origen.value; });
  if (formBusqueda.destino.selectedOptions[0]?.disabled) formBusqueda.destino.value = "";
});

async function cargarCiudades() {
  try {
    const r = await api("GET", "/api/vuelos/ciudades");
    r.origenes.forEach((c) => formBusqueda.origen.add(new Option(c, c)));
    r.destinos.forEach((c) => formBusqueda.destino.add(new Option(c, c)));
  } catch (err) { avisar(textoError(err), "error"); }
}

function validarBusqueda() {
  const f = formBusqueda;
  const pasajeros = f.pasajeros.value;
  const okDestino = marcarCampo(f.destino, f.origen.value && f.origen.value === f.destino.value
    ? "El destino debe ser distinto del origen" : "");
  let errorFecha = "";
  if (f.fecha.validity.badInput) errorFecha = "Fecha incompleta o inválida";
  else if (f.fecha.value && f.fecha.value < f.fecha.min) errorFecha = "La fecha no puede ser pasada";
  else if (f.fecha.value && f.fecha.value > f.fecha.max) errorFecha = "Solo se puede buscar hasta un año adelante";
  const okFecha = marcarCampo(f.fecha, errorFecha);
  const okPasajeros = marcarCampo(f.pasajeros, new RegExp(`^[1-${LIMITES.asientos}]$`).test(pasajeros)
    ? "" : `Seleccione entre 1 y ${LIMITES.asientos} pasajeros`);
  return okDestino && okFecha && okPasajeros;
}
["origen", "destino", "fecha", "pasajeros"].forEach((n) => formBusqueda[n].addEventListener("change", validarBusqueda));

async function buscarVuelos() {
  if (!validarBusqueda()) return;
  const params = new URLSearchParams();
  ["origen", "destino", "fecha", "pasajeros"].forEach((k) => formBusqueda[k].value && params.set(k, formBusqueda[k].value));
  const cuerpo = $("tabla-vuelos");
  try {
    const r = await api("GET", `/api/vuelos?${params}`);
    $("resumen-vuelos").textContent = `${r.total} vuelo(s) encontrados${r.total === 100 ? " (mostrando los primeros 100)" : ""}`;
    cuerpo.innerHTML = r.vuelos.length ? "" : `<tr><td colspan="8" class="vacio">No hay vuelos con esos filtros</td></tr>`;
    r.vuelos.forEach((v) => {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td>${escapar(v.codigo)}</td><td>${escapar(v.aerolinea)}</td>
        <td>${escapar(v.origen)} → ${escapar(v.destino)}</td>
        <td>${fechaHora(v.fecha_salida)}</td><td>${fechaHora(v.fecha_llegada)}</td>
        <td>${dinero(v.precio)}</td><td>${v.asientos_disponibles} / ${v.asientos_totales}</td><td></td>`;
      const boton = document.createElement("button");
      boton.className = "mini primario";
      boton.textContent = "Elegir asientos";
      boton.disabled = v.asientos_disponibles === 0;
      boton.onclick = () => abrirMapa(v.id);
      tr.lastElementChild.append(boton);
      cuerpo.append(tr);
    });
  } catch (err) { avisar(textoError(err), "error"); }
}
formBusqueda.addEventListener("submit", (e) => { e.preventDefault(); buscarVuelos(); });

// ---------- Mapa de asientos ----------

async function abrirMapa(vueloId, edicion = null) {
  salirDelMapa();
  Object.assign(mapa, {
    vueloId, datos: null, claseActiva: null, edicion, expiran: {}, pasajeros: {},
    liberadosPorMi: new Set(), claveSeleccion: null,
  });
  if (edicion) edicion.detalle.forEach((p) => {
    mapa.pasajeros[p.asiento] = { nombre: p.nombre, tipo_documento: p.tipo_documento, documento: p.documento };
  });
  document.querySelectorAll(".vista").forEach((v) => v.classList.add("oculta"));
  $("vista-asientos").classList.remove("oculta");
  document.querySelectorAll(".tab").forEach((t) => t.classList.remove("activa"));
  $("mapa-asientos").innerHTML = "";
  await cargarMapa();
  mapa.temporizador = setInterval(cargarMapa, INTERVALO_ACTUALIZACION);
  mapa.reloj = setInterval(pintarReloj, 1000);
  window.scrollTo(0, 0);
}

// Al salir del mapa se liberan los asientos retenidos que no se confirmaron
function salirDelMapa() {
  clearInterval(mapa.temporizador);
  clearInterval(mapa.reloj);
  mapa.temporizador = mapa.reloj = null;
  if (mapa.vueloId && estado.token) {
    Object.keys(mapa.expiran).forEach((a) => api("DELETE", `/api/vuelos/${mapa.vueloId}/asientos/${a}/retener`).catch(() => {}));
  }
  mapa.expiran = {};
  mapa.vueloId = null;
}

async function cargarMapa() {
  if (!mapa.vueloId || mapa.cargando) return;
  mapa.cargando = true;
  try {
    const datos = await api("GET", `/api/vuelos/${mapa.vueloId}/asientos`);
    const antes = new Set(Object.keys(mapa.expiran));
    mapa.datos = datos;
    mapa.expiran = {};
    datos.mis_retenciones.forEach((r) => { mapa.expiran[r.asiento] = Date.now() + r.segundos_restantes * 1000; });
    // Aviso si una selección venció
    const vencidos = [...antes].filter((a) => !mapa.expiran[a] && !mapa.liberadosPorMi.has(a));
    if (vencidos.length) avisar(`Su selección de ${vencidos.join(", ")} expiró y fue liberada`, "error");
    mapa.liberadosPorMi.clear();

    mapa.claseDe = {};
    mapa.precioClase = {};
    datos.clases.forEach((c) => {
      mapa.precioClase[c.clase] = c.precio;
      c.filas.forEach((f) => c.grupos.flat().forEach((l) => { mapa.claseDe[`${f}${l}`] = c.clase; }));
    });
    if (!mapa.claseActiva) mapa.claseActiva = datos.clases[datos.clases.length - 1].clase;
    pintarMapa();
    $("mapa-actualizado").textContent = `Actualizado ${new Date().toLocaleTimeString()} · se actualiza cada ${INTERVALO_ACTUALIZACION / 1000} s`;
  } catch (err) {
    $("mapa-actualizado").textContent = textoError(err);
    if (err.status === 404) { avisar(err.message, "error"); mostrarVista("vuelos"); }
  } finally {
    mapa.cargando = false;
  }
}

function estadoAsiento(asiento) {
  const e = mapa.datos.estados[asiento] || "DISPONIBLE";
  if (mapa.edicion && mapa.datos.mis_reservados[asiento] === mapa.edicion.reservaId) {
    return mapa.edicion.quitados.has(asiento) ? "QUITADO" : "MIO";
  }
  return e;
}

// Asientos que forman la reserva (los de la reserva en edición que no se quitaron + los retenidos)
function asientosSeleccionados() {
  const propios = mapa.edicion
    ? Object.keys(mapa.datos.mis_reservados).filter((a) => mapa.datos.mis_reservados[a] === mapa.edicion.reservaId
        && !mapa.edicion.quitados.has(a))
    : [];
  return [...propios, ...Object.keys(mapa.expiran)].sort(ordenAsientos);
}

function ordenAsientos(a, b) {
  return parseInt(a) - parseInt(b) || a.slice(-1).localeCompare(b.slice(-1));
}

function pintarMapa() {
  const { datos } = mapa;
  const v = datos.vuelo;
  $("av-ruta").innerHTML = `${escapar(v.origen)} <span class="nota">a</span> ${escapar(v.destino)}`;
  $("av-fecha").textContent = `Salida ${new Date(v.fecha_salida).toLocaleDateString("es-EC", { weekday: "short", day: "numeric", month: "short", year: "numeric" })} · ${duracion(v.fecha_salida, v.fecha_llegada)}`;
  $("av-duracion").textContent = duracion(v.fecha_salida, v.fecha_llegada);
  $("av-sale").textContent = hora(v.fecha_salida);
  $("av-llega").textContent = hora(v.fecha_llegada);
  $("av-origen").textContent = v.origen;
  $("av-destino").textContent = v.destino;
  $("av-aerolinea").textContent = `${v.aerolinea} ${v.codigo}`;
  $("av-avion").textContent = datos.avion;

  // Pestañas por clase (Economy primero, como en la cabina)
  const pestanas = $("pestanas-clase");
  pestanas.innerHTML = "";
  [...datos.clases].reverse().forEach((c) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = `pildora${c.clase === mapa.claseActiva ? " activa" : ""}`;
    b.innerHTML = `${escapar(c.nombre)} <small>${dinero(c.precio)}</small>`;
    b.onclick = () => { mapa.claseActiva = c.clase; pintarMapa(); };
    pestanas.append(b);
  });

  const clase = datos.clases.find((c) => c.clase === mapa.claseActiva);
  const r = clase.resumen;
  $("mapa-titulo").textContent = `Asientos en ${clase.nombre} ${v.codigo}`;
  $("mapa-resumen").innerHTML = `Ocupados: ${r.ocupados} / ${r.total} (${Math.round((r.ocupados / r.total) * 100)}%)<br>
    Bloqueados: ${r.bloqueados} / ${r.total}<br>Disponibles: ${r.disponibles} / ${r.total} · ${dinero(clase.precio)} por asiento`;

  // Grilla: columna de número de fila + letras con un espacio por cada pasillo
  const columnas = [];
  clase.grupos.forEach((g, i) => { if (i) columnas.push(null); columnas.push(...g); });
  const grilla = $("mapa-asientos");
  grilla.style.gridTemplateColumns = `var(--ancho-fila) ${columnas.map((c) => (c ? "var(--ancho-asiento)" : "var(--ancho-pasillo)")).join(" ")}`;
  grilla.innerHTML = "";
  grilla.append(document.createElement("span"));
  columnas.forEach((c) => {
    const s = document.createElement("span");
    s.className = "letra";
    s.textContent = c || "";
    grilla.append(s);
  });
  clase.filas.forEach((fila) => {
    const n = document.createElement("span");
    n.className = "num-fila";
    n.textContent = fila;
    grilla.append(n);
    columnas.forEach((letra) => {
      if (!letra) { grilla.append(document.createElement("span")); return; }
      const asiento = `${fila}${letra}`;
      const e = estadoAsiento(asiento);
      const b = document.createElement("button");
      b.type = "button";
      b.className = `asiento ${e}`;
      b.textContent = letra;
      b.title = `${asiento} · ${descripcionEstado(e)}`;
      b.setAttribute("aria-label", b.title);
      b.onclick = () => clicAsiento(asiento, e);
      grilla.append(b);
    });
  });

  pintarSeleccion();
  pintarReloj();
}

function descripcionEstado(e) {
  return {
    DISPONIBLE: "Disponible", BLOQUEADO: "Bloqueado (no disponible o en proceso por otro usuario)",
    OCUPADO: "Ocupado", SELECCIONADO: "Seleccionado por usted", MIO: "De esta reserva (clic para quitar)",
    QUITADO: "Se quitará de la reserva (clic para mantener)", RESERVADO: "Ya reservado por usted en otra reserva",
  }[e];
}

async function clicAsiento(asiento, e) {
  if (e === "DISPONIBLE") {
    if (!estado.token) {
      estado.pendiente = { vista: "asientos", vueloId: mapa.vueloId };
      avisar("Inicie sesión para seleccionar asientos", "info");
      mostrarVista("acceso");
      return;
    }
    if (asientosSeleccionados().length >= LIMITES.asientos) {
      avisar(`Puede tener máximo ${LIMITES.asientos} asientos por reserva`, "error");
      return;
    }
    try {
      await api("POST", `/api/vuelos/${mapa.vueloId}/asientos/${asiento}/retener`);
    } catch (err) {
      avisar(err.status === 409 ? `El asiento ${asiento} acaba de ser tomado por otro usuario` : textoError(err), "error");
    }
    await cargarMapa();
  } else if (e === "SELECCIONADO") {
    mapa.liberadosPorMi.add(asiento);
    try { await api("DELETE", `/api/vuelos/${mapa.vueloId}/asientos/${asiento}/retener`); } catch (err) { avisar(textoError(err), "error"); }
    await cargarMapa();
  } else if (e === "MIO") {
    mapa.edicion.quitados.add(asiento);
    pintarMapa();
  } else if (e === "QUITADO") {
    if (asientosSeleccionados().length >= LIMITES.asientos) {
      avisar(`Puede tener máximo ${LIMITES.asientos} asientos por reserva`, "error");
      return;
    }
    mapa.edicion.quitados.delete(asiento);
    pintarMapa();
  } else {
    avisar(`El asiento ${asiento} no está disponible: ${descripcionEstado(e).toLowerCase()}`, "info");
  }
}

function pintarReloj() {
  const reloj = $("sel-reloj");
  const expiraciones = Object.values(mapa.expiran);
  if (!expiraciones.length) { reloj.classList.add("oculta"); return; }
  const segundos = Math.max(0, Math.round((Math.min(...expiraciones) - Date.now()) / 1000));
  reloj.textContent = `Retenidos ${Math.floor(segundos / 60)}:${String(segundos % 60).padStart(2, "0")}`;
  reloj.classList.toggle("urgente", segundos <= 60);
  reloj.classList.remove("oculta");
}

// Formulario de pasajeros: solo se reconstruye cuando cambia la selección (no en cada actualización)
function pintarSeleccion() {
  const seleccion = asientosSeleccionados();
  const clave = seleccion.join(",");
  const total = seleccion.reduce((s, a) => s + precioAsiento(a), 0);
  $("sel-titulo").textContent = mapa.edicion ? `Modificar reserva #${mapa.edicion.reservaId}` : "Su selección";
  $("sel-vacia").classList.toggle("oculta", seleccion.length > 0);
  $("sel-total").classList.toggle("oculta", !seleccion.length);
  $("btn-confirmar").classList.toggle("oculta", !seleccion.length);
  $("btn-confirmar").textContent = mapa.edicion ? "Guardar cambios" : "Confirmar reserva";
  $("btn-cancelar").classList.toggle("oculta", !mapa.edicion && !seleccion.length);
  $("btn-cancelar").textContent = mapa.edicion ? "Cancelar edición" : "Cancelar selección";
  $("sel-total").innerHTML = `<span>Total (${seleccion.length} asiento${seleccion.length === 1 ? "" : "s"})</span><span>${dinero(total)}</span>`;
  if (clave === mapa.claveSeleccion) return;
  mapa.claveSeleccion = clave;

  const lista = $("lista-pasajeros");
  lista.innerHTML = "";
  seleccion.forEach((asiento, i) => {
    const datos = mapa.pasajeros[asiento] || { nombre: "", tipo_documento: "CEDULA", documento: "" };
    mapa.pasajeros[asiento] = datos;
    const clase = mapa.datos.clases.find((c) => c.clase === mapa.claseDe[asiento]);
    const caja = document.createElement("div");
    caja.className = "pasajero";
    caja.innerHTML = `
      <div class="pasajero-cabecera"><span>Pasajero ${i + 1} · Asiento ${asiento}</span>
        <span class="precio">${escapar(clase.nombre)} · ${dinero(precioAsiento(asiento))}</span></div>
      <div class="campo">
        <label for="p-nombre-${asiento}">Nombre completo</label>
        <input id="p-nombre-${asiento}" name="nombre" maxlength="${LIMITES.nombre}" autocomplete="off" required>
        <small class="error-campo"></small>
      </div>
      <div class="campo">
        <label for="p-doc-${asiento}">Documento</label>
        <div class="doc">
          <select name="tipo_documento" aria-label="Tipo de documento">
            <option value="CEDULA">Cédula</option><option value="PASAPORTE">Pasaporte</option>
          </select>
          <input id="p-doc-${asiento}" name="documento" autocomplete="off" required>
        </div>
        <small class="error-campo"></small>
      </div>`;
    const nombre = caja.querySelector("[name=nombre]");
    const tipo = caja.querySelector("[name=tipo_documento]");
    const doc = caja.querySelector("[name=documento]");
    nombre.value = datos.nombre;
    tipo.value = datos.tipo_documento;
    doc.value = datos.documento;
    configurarDocumento(tipo, doc);

    nombre.addEventListener("input", () => {
      filtrarCampo(nombre, Filtro.nombre);
      datos.nombre = nombre.value;
      if (nombre.classList.contains("invalido")) marcarCampo(nombre, Validar.nombre(nombre.value.trim()));
    });
    nombre.addEventListener("blur", () => {
      nombre.value = datos.nombre = formatearNombre(nombre.value);
      if (nombre.value) marcarCampo(nombre, Validar.nombre(nombre.value));
    });
    tipo.addEventListener("change", () => {
      datos.tipo_documento = tipo.value;
      doc.value = "";
      datos.documento = "";
      configurarDocumento(tipo, doc);
      marcarCampo(doc, "");
    });
    doc.addEventListener("input", () => {
      filtrarCampo(doc, tipo.value === "CEDULA" ? Filtro.cedula : Filtro.pasaporte);
      datos.documento = doc.value;
      if (doc.classList.contains("invalido")) marcarCampo(doc, Validar.documento(tipo.value, doc.value));
    });
    doc.addEventListener("blur", () => doc.value && marcarCampo(doc, Validar.documento(tipo.value, doc.value)));
    lista.append(caja);
  });
}

function configurarDocumento(tipo, doc) {
  const cedula = tipo.value === "CEDULA";
  doc.maxLength = cedula ? 10 : 9;
  doc.inputMode = cedula ? "numeric" : "text";
  doc.placeholder = cedula ? "10 dígitos" : "6 a 9 caracteres";
}

function precioAsiento(asiento) {
  return mapa.precioClase[mapa.claseDe[asiento]] || 0;
}

$("form-pasajeros").addEventListener("submit", async (e) => {
  e.preventDefault();
  const seleccion = asientosSeleccionados();
  if (!seleccion.length) { avisar("Seleccione al menos un asiento", "error"); return; }

  // Validación de todos los campos antes de enviar
  let valido = true;
  document.querySelectorAll("#lista-pasajeros .pasajero").forEach((caja) => {
    const nombre = caja.querySelector("[name=nombre]");
    const tipo = caja.querySelector("[name=tipo_documento]");
    const doc = caja.querySelector("[name=documento]");
    valido = marcarCampo(nombre, Validar.nombre(limpiarNombre(nombre.value))) && valido;
    valido = marcarCampo(doc, Validar.documento(tipo.value, doc.value)) && valido;
  });
  const documentos = seleccion.map((a) => mapa.pasajeros[a].documento);
  if (valido && new Set(documentos).size !== documentos.length) {
    avisar("Un mismo documento no puede repetirse en la reserva", "error");
    valido = false;
  }
  if (!valido) { document.querySelector("#lista-pasajeros .invalido")?.focus(); return; }

  const pasajeros = seleccion.map((a) => ({
    asiento: a, nombre: limpiarNombre(mapa.pasajeros[a].nombre),
    tipo_documento: mapa.pasajeros[a].tipo_documento, documento: mapa.pasajeros[a].documento,
  }));
  const boton = $("btn-confirmar");
  boton.disabled = true;
  try {
    const r = mapa.edicion
      ? await api("PUT", `/api/reservas/${mapa.edicion.reservaId}`, { pasajeros })
      : await api("POST", "/api/reservas", { vuelo_id: mapa.vueloId, pasajeros });
    mapa.expiran = {}; // ya no son retenciones: pasaron a OCUPADO
    avisar(`${r.mensaje}: reserva #${r.reserva.id}, asientos ${r.reserva.asientos.join(", ")}, total ${dinero(r.reserva.total)}`);
    mostrarVista("reservas");
  } catch (err) {
    if (err.status === 409 && err.datos.detalle && err.datos.detalle.asientos_no_disponibles) {
      avisar(`Otro usuario tomó: ${err.datos.detalle.asientos_no_disponibles.join(", ")}. Elija otros asientos.`, "error");
    } else avisar(textoError(err), "error");
    await cargarMapa();
  } finally {
    boton.disabled = false;
  }
});

$("btn-volver").addEventListener("click", () => mostrarVista(mapa.edicion ? "reservas" : "vuelos"));

// Cancelar: en edición descarta los cambios; en una reserva nueva libera los asientos elegidos
$("btn-cancelar").addEventListener("click", async () => {
  if (mapa.edicion) {
    const ok = await confirmar({
      titulo: `Cancelar edición de la reserva #${mapa.edicion.reservaId}`, textoOk: "Sí, descartar",
      html: "<p>Se descartarán los cambios y la reserva quedará como estaba. ¿Continuar?</p>",
    });
    if (!ok) return;
    mostrarVista("reservas"); // salirDelMapa libera los asientos nuevos retenidos
    avisar("Cambios descartados, la reserva no se modificó", "info");
    return;
  }
  const ok = await confirmar({
    titulo: "Cancelar selección", textoOk: "Sí, liberar",
    html: `<p>Se liberarán los asientos <strong>${Object.keys(mapa.expiran).sort(ordenAsientos).join(", ")}</strong> para otros usuarios. ¿Continuar?</p>`,
  });
  if (!ok) return;
  const asientos = Object.keys(mapa.expiran);
  asientos.forEach((a) => mapa.liberadosPorMi.add(a));
  await Promise.all(asientos.map((a) => api("DELETE", `/api/vuelos/${mapa.vueloId}/asientos/${a}/retener`).catch(() => {})));
  asientos.forEach((a) => delete mapa.pasajeros[a]);
  avisar("Selección cancelada, los asientos quedaron libres", "info");
  await cargarMapa();
});

// ---------- Mis reservas ----------

async function cargarReservas() {
  const filtro = $("filtro-estado").value;
  const cuerpo = $("tabla-reservas");
  try {
    const r = await api("GET", `/api/reservas${filtro ? `?estado=${filtro}` : ""}`);
    cuerpo.innerHTML = r.reservas.length ? "" : `<tr><td colspan="7" class="vacio">No tiene reservas</td></tr>`;
    r.reservas.forEach((res) => {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td>${res.id}</td><td>${escapar(res.codigo_vuelo)}</td><td>${escapar(res.asientos)}</td>
        <td>${dinero(res.total)}</td><td><span class="etiqueta ${res.estado}">${res.estado}</span></td>
        <td>${fechaHora(res.fecha_reserva)}</td><td class="acciones"></td>`;
      const acciones = tr.lastElementChild;
      const boton = (texto, clase, accion) => {
        const b = document.createElement("button");
        b.className = `mini ${clase}`;
        b.textContent = texto;
        b.onclick = accion;
        acciones.append(b);
      };
      boton("Detalle", "secundario", () => verDetalle(res.id));
      if (res.estado === "CONFIRMADA") {
        boton("Modificar", "primario", () => modificarReserva(res.id));
        boton("Cancelar", "peligro", () => cancelarReserva(res));
      }
      cuerpo.append(tr);
    });
  } catch (err) { avisar(textoError(err), "error"); }
}

async function verDetalle(id) {
  try {
    const { reserva, vuelo } = await api("GET", `/api/reservas/${id}`);
    const pasajeros = reserva.detalle_pasajeros.map((p) =>
      `<li><strong>${p.asiento}</strong> (${p.clase}) · ${escapar(p.nombre)} · ${p.tipo_documento} ${escapar(p.documento)} · ${dinero(p.precio)}</li>`).join("");
    await confirmar({
      titulo: `Reserva #${reserva.id} · ${reserva.estado}`, soloCerrar: true,
      html: `<p>${escapar(vuelo.aerolinea)} ${escapar(vuelo.codigo)}: ${escapar(vuelo.origen)} → ${escapar(vuelo.destino)}<br>
        Salida ${fechaHora(vuelo.fecha_salida)} · Llegada ${fechaHora(vuelo.fecha_llegada)}</p>
        <ul class="lista-detalle">${pasajeros}</ul><p><strong>Total: ${dinero(reserva.total)}</strong></p>`,
    });
  } catch (err) { avisar(textoError(err), "error"); }
}

async function modificarReserva(id) {
  try {
    const { reserva } = await api("GET", `/api/reservas/${id}`);
    abrirMapa(reserva.vuelo_id, { reservaId: reserva.id, quitados: new Set(), detalle: reserva.detalle_pasajeros });
  } catch (err) { avisar(textoError(err), "error"); }
}

async function cancelarReserva(res) {
  const ok = await confirmar({
    titulo: `Cancelar reserva #${res.id}`, textoOk: "Sí, cancelar",
    html: `<p>Los asientos <strong>${escapar(res.asientos)}</strong> quedarán libres para otros usuarios. ¿Continuar?</p>`,
  });
  if (!ok) return;
  try {
    const r = await api("DELETE", `/api/reservas/${res.id}`);
    avisar(r.mensaje);
    cargarReservas();
  } catch (err) { avisar(textoError(err), "error"); }
}

$("filtro-estado").addEventListener("change", cargarReservas);

// ---------- Estado de servicios ----------

async function cargarEstado() {
  $("api-url").textContent = API;
  const caja = $("estado-servicios");
  const host = new URL(API).hostname;
  try {
    const r = await api("GET", "/api/salud");
    caja.innerHTML = Object.entries(r.servicios).map(([nombre, s]) => `
      <div class="panel"><strong>${escapar(nombre)}</strong><span class="nota">${escapar(host)}:${s.puerto}</span>
      <span><span class="etiqueta ${escapar(s.estado)}">${escapar(s.estado)}</span></span>
      <a href="http://${escapar(host)}:${s.puerto}/apidocs" target="_blank" rel="noopener">Ver contrato (Swagger)</a></div>`).join("");
  } catch (err) {
    caja.innerHTML = `<div class="panel"><strong>Gateway</strong><span class="etiqueta caído">caído</span><span class="nota">${escapar(textoError(err))}</span></div>`;
  }
}

// ---------- Inicio ----------

document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => mostrarVista(t.dataset.vista)));
window.addEventListener("pagehide", salirDelMapa);
pintarSesion();
cargarCiudades();
buscarVuelos();
