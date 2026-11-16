# fps_web_autofill

Flutter web: the browser's saved-data suggestions (Chrome autofill / autocomplete,
password manager) appear on the **first click** into a text field.

Flutter web only creates the real `<input>` element after a field gains focus, so the
click lands on the Flutter canvas and Chrome never opens its suggestion list. This
package places a transparent, real `<input>` (with the matching `autocomplete`
attribute) over an empty field that has `autofillHints` while the mouse is over it:

- picking a suggestion copies the values into the Flutter fields (all fields of the
  same page / `AutofillGroup` are filled at once);
- typing hands the keystrokes and the focus over to the Flutter field.

Touch devices (no hover) and non-web platforms are unaffected.

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FpsWebAutofill.inditas();
  runApp(const MyApp());
}
```
