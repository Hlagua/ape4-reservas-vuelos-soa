// Inicio de sesión y modal de "Crear cuenta"
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';

/// Devuelve true al hacer Navigator.pop si el usuario inició sesión.
class PantallaAcceso extends StatefulWidget {
  const PantallaAcceso({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaAcceso> createState() => _PantallaAccesoState();
}

class _PantallaAccesoState extends State<PantallaAcceso> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _verClave = false;
  bool _enviando = false;
  String? _errorCredenciales;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _ingresar() async {
    setState(() => _errorCredenciales = null);
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      await widget.sesion.iniciar(_email.text, _password.text);
      if (!mounted) return;
      avisar(context, 'Inicio de sesión exitoso');
      Navigator.pop(context, true);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.status == 401) {
        setState(() => _errorCredenciales = 'Email o contraseña incorrectos');
      } else {
        avisar(context, e.texto, TipoAviso.error);
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _crearCuenta() async {
    final email = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ModalRegistro(sesion: widget.sesion),
    );
    if (email != null && mounted) {
      _email.text = email;
      avisar(context, 'Usuario registrado correctamente. Ya puede iniciar sesión.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Iniciar sesión')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Centrado(
          ancho: 420,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Iniciar sesión', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    const Text('Ingrese para seleccionar asientos y gestionar sus reservas.'),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      maxLength: maxEmail,
                      inputFormatters: [Filtro.formateador(Filtro.email)],
                      decoration: const InputDecoration(labelText: 'Email', hintText: 'nombre@uta.edu.ec', counterText: ''),
                      validator: Validar.email,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: !_verClave,
                      maxLength: maxPassword,
                      inputFormatters: [Filtro.formateador(Filtro.password)],
                      decoration: InputDecoration(labelText: 'Contraseña', counterText: '', errorText: _errorCredenciales),
                      validator: (v) => (v ?? '').isEmpty ? 'La contraseña es obligatoria' : null,
                      onFieldSubmitted: (_) => _ingresar(),
                    ),
                    CheckboxListTile(
                      value: _verClave,
                      onChanged: (v) => setState(() => _verClave = v ?? false),
                      title: const Text('Mostrar contraseña'),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _enviando ? null : _ingresar,
                      child: Text(_enviando ? 'Procesando...' : 'Ingresar'),
                    ),
                    const SizedBox(height: 16),
                    const Row(children: [
                      Expanded(child: Divider()),
                      Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('¿No tiene una cuenta?')),
                      Expanded(child: Divider()),
                    ]),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _enviando ? null : _crearCuenta, child: const Text('Crear cuenta')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal de registro; devuelve el email creado al cerrarse con éxito.
class ModalRegistro extends StatefulWidget {
  const ModalRegistro({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<ModalRegistro> createState() => _ModalRegistroState();
}

class _ModalRegistroState extends State<ModalRegistro> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmar = TextEditingController();
  bool _verClaves = false;
  bool _enviando = false;
  Map<String, String> _erroresServidor = {};

  @override
  void dispose() {
    _nombre.dispose();
    _email.dispose();
    _password.dispose();
    _confirmar.dispose();
    super.dispose();
  }

  Future<void> _registrar() async {
    _nombre.text = formatearNombre(_nombre.text);
    setState(() => _erroresServidor = {});
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      final r = await widget.sesion.api.registrar(_nombre.text, _email.text, _password.text);
      if (mounted) Navigator.pop(context, (r['usuario'] as Map)['email'] as String);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.status == 409) {
        setState(() => _erroresServidor = {'email': 'Este email ya está registrado'});
      } else if (e.status == 400 && e.detalle is Map) {
        setState(() => _erroresServidor = (e.detalle as Map).map((k, v) => MapEntry('$k', '$v')));
      } else {
        avisar(context, e.texto, TipoAviso.error);
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Crear cuenta'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onFocusChange: (enfocado) {
                    if (!enfocado) _nombre.text = formatearNombre(_nombre.text);
                  },
                  child: TextFormField(
                    controller: _nombre,
                    autofocus: true,
                    maxLength: maxNombre,
                    textCapitalization: TextCapitalization.words,
                    inputFormatters: [Filtro.formateador(Filtro.nombre)],
                    decoration: InputDecoration(
                      labelText: 'Nombre completo',
                      helperText: 'Solo letras, de 3 a $maxNombre caracteres.',
                      errorText: _erroresServidor['nombre'],
                    ),
                    validator: (v) => Validar.nombre(v?.trim()),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  maxLength: maxEmail,
                  inputFormatters: [Filtro.formateador(Filtro.email)],
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'nombre@uta.edu.ec',
                    helperText: 'En minúsculas, sin espacios, máximo $maxEmail caracteres.',
                    errorText: _erroresServidor['email'],
                  ),
                  validator: Validar.email,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: !_verClaves,
                  maxLength: maxPassword,
                  inputFormatters: [Filtro.formateador(Filtro.password)],
                  decoration: InputDecoration(
                    labelText: 'Contraseña',
                    helperText: 'De $minPassword a $maxPassword caracteres, con letras y números, sin espacios.',
                    helperMaxLines: 2,
                    counterText: '',
                    errorText: _erroresServidor['password'],
                  ),
                  validator: Validar.password,
                ),
                const SizedBox(height: 8),
                // enableInteractiveSelection en false impide pegar: la confirmación debe escribirse
                TextFormField(
                  controller: _confirmar,
                  obscureText: !_verClaves,
                  maxLength: maxPassword,
                  enableInteractiveSelection: false,
                  inputFormatters: [Filtro.formateador(Filtro.password)],
                  decoration: const InputDecoration(labelText: 'Confirmar contraseña', counterText: ''),
                  validator: (v) {
                    if ((v ?? '').isEmpty) return 'Confirme la contraseña';
                    return v == _password.text ? null : 'Las contraseñas no coinciden';
                  },
                ),
                CheckboxListTile(
                  value: _verClaves,
                  onChanged: (v) => setState(() => _verClaves = v ?? false),
                  title: const Text('Mostrar contraseñas'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _enviando ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _enviando ? null : _registrar,
          child: Text(_enviando ? 'Procesando...' : 'Crear cuenta'),
        ),
      ],
    );
  }
}
