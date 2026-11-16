/// Böngészős automatikus kitöltés első kattintásra (Flutter web, egér).
///
/// Használat: a `runApp` előtt (a binding inicializálása után)
/// `FpsWebAutofill.inditas();` – mobil és asztali appban nem csinál semmit.
library;

export 'src/stub.dart' if (dart.library.js_interop) 'src/web.dart';
