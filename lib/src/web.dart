// Webes megvalósítás.
//
// A Flutter web a böngésző igazi <input> mezőjét csak a fókusz UTÁN hozza
// létre, így az egérkattintás a Flutter rajzfelületére esik, és a Chrome nem
// nyitja meg a mentett adatok listáját. Itt, amikor az egér egy üres, kitöltési
// jelzéssel (autofillHints) ellátott mező fölé ér, egy átlátszó, valódi
// <input> kerül pontosan a mező fölé, egy közös <form>-ban az oldal többi
// kitölthető mezőjével. Így:
//  - kattintásra a Chrome felkínálja a mentett adatokat;
//  - ha a felhasználó választ, minden kitöltött érték a Flutter-mezőkbe kerül;
//  - ha inkább gépel, a leütött karakter a Flutter-mezőbe kerül, és a fókusz
//    átmegy a Flutter-mezőre.
// Érintőképernyőn (nincs egérmutató) nem csinál semmit.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class FpsWebAutofill {
  static _Motor? _motor;

  /// Egyszer kell hívni, a `WidgetsFlutterBinding.ensureInitialized()` után.
  static void inditas() {
    if (_motor != null) return;
    try {
      _motor = _Motor()..indit();
    } catch (_) {}
  }
}

/// Flutter AutofillHints → HTML autocomplete.
const Map<String, String> _hintek = {
  'email': 'email',
  'username': 'username',
  'password': 'current-password',
  'newPassword': 'new-password',
  'newUsername': 'username',
  'name': 'name',
  'givenName': 'given-name',
  'familyName': 'family-name',
  'middleName': 'additional-name',
  'namePrefix': 'honorific-prefix',
  'nameSuffix': 'honorific-suffix',
  'nickname': 'nickname',
  'telephoneNumber': 'tel',
  'telephoneNumberDevice': 'tel',
  'telephoneNumberNational': 'tel-national',
  'telephoneNumberCountryCode': 'tel-country-code',
  'telephoneNumberLocal': 'tel-local',
  'postalCode': 'postal-code',
  'postalAddress': 'street-address',
  'fullStreetAddress': 'street-address',
  'streetAddressLine1': 'address-line1',
  'streetAddressLine2': 'address-line2',
  'streetAddressLine3': 'address-line3',
  'addressCity': 'address-level2',
  'addressCityAndState': 'address-level2',
  'addressState': 'address-level1',
  'sublocality': 'address-level3',
  'countryName': 'country-name',
  'countryCode': 'country',
  'organizationName': 'organization',
  'jobTitle': 'organization-title',
  'birthday': 'bday',
  'birthdayDay': 'bday-day',
  'birthdayMonth': 'bday-month',
  'birthdayYear': 'bday-year',
  'oneTimeCode': 'one-time-code',
  'url': 'url',
};

class _Mezo {
  _Mezo(this.elem, this.w, this.doboz, this.szoveg, this.route, this.csoport);
  final Element elem;
  final EditableText w;
  final RenderBox doboz; // az egész mező (InputDecorator), ide kattint a felhasználó
  final RenderBox szoveg; // maga a szövegsor
  final ModalRoute<dynamic>? route;
  // a Flutter AutofillGroup-ja: külön csoport = külön <form> (pl. belépés vs. pénztár)
  final Object? csoport;
  web.HTMLInputElement? input;

  String get hint => w.autofillHints!.first;
  bool get jelszo => hint == 'password' || hint == 'newPassword';
  bool get ures => w.controller.text.isEmpty;
  bool get el => elem.mounted && doboz.attached && doboz.hasSize && szoveg.attached;
}

class _Motor {
  web.HTMLFormElement? _form;
  List<_Mezo> _mezok = [];
  _Mezo? _aktiv; // az egér alatti (vagy fókuszban lévő) mező
  _Mezo? _atadva; // gépelés indult: a Flutter-mező kapja a fókuszt
  int _kepkocka = 0;
  int _gyujtesKepkocka = -1;
  DateTime _gyujtesIdo = DateTime.fromMillisecondsSinceEpoch(0);
  bool _mozgasVar = false;
  double _px = 0, _py = 0;
  Timer? _kitoltesIdozito;

  void indit() {
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      _kepkocka++;
      _igazit();
    });
    web.window.addEventListener(
        'pointermove',
        ((web.PointerEvent e) {
          if (e.pointerType != 'mouse') return;
          _px = e.clientX.toDouble();
          _py = e.clientY.toDouble();
          if (_mozgasVar) return;
          _mozgasVar = true;
          web.window.requestAnimationFrame(((JSNumber _) {
            _mozgasVar = false;
            try {
              _mozgas();
            } catch (_) {}
          }).toJS);
        }).toJS,
        true.toJS);
  }

  // ---- DOM ----

  web.HTMLFormElement _urlap() {
    final f = _form;
    if (f != null) return f;
    final stilus = web.document.createElement('style') as web.HTMLStyleElement;
    stilus.textContent = '''
form.fpsaf{position:fixed;left:0;top:0;width:0;height:0;margin:0;padding:0;z-index:2147483000;}
input.fpsaf{position:fixed;margin:0;border:0;outline:none;box-sizing:border-box;background:transparent;color:transparent;pointer-events:none;cursor:text;padding-top:0;padding-bottom:0;padding-right:0;}
input.fpsaf:-webkit-autofill{-webkit-box-shadow:0 0 0 1000px transparent inset;-webkit-text-fill-color:transparent;transition:background-color 99999s;}
''';
    web.document.head?.append(stilus);
    final uj = web.document.createElement('form') as web.HTMLFormElement;
    uj.className = 'fpsaf';
    uj.setAttribute('autocomplete', 'on');
    uj.addEventListener(
        'submit', ((web.Event e) => e.preventDefault()).toJS);
    web.document.body?.append(uj);
    _form = uj;
    return uj;
  }

  web.Element? _flutterView() => web.document.querySelector('flutter-view');

  // ---- mezők gyűjtése ----

  /// A widgetfa bejárása drága, ezért ritkítva fut: gyakrabban, ha az egér
  /// épp egy szövegmező fölött van ([surgos]), ritkábban egyébként.
  void _gyujt(bool surgos) {
    final most = DateTime.now();
    final eltelt = most.difference(_gyujtesIdo).inMilliseconds;
    if (_gyujtesKepkocka == _kepkocka && eltelt < 1500) return;
    if (eltelt < (surgos ? 150 : 700)) return;
    _gyujtesKepkocka = _kepkocka;
    _gyujtesIdo = most;

    final regi = {for (final m in _mezok) m.elem: m};
    final uj = <_Mezo>[];
    void bejar(Element el) {
      final w = el.widget;
      if (w is Offstage && w.offstage) return;
      if (w is EditableText) {
        final h = w.autofillHints;
        if (h != null &&
            h.isNotEmpty &&
            _hintek.containsKey(h.first) &&
            !w.readOnly &&
            w.focusNode.canRequestFocus) {
          final szoveg = el.findRenderObject();
          RenderObject? doboz;
          el.visitAncestorElements((a) {
            if (a.widget is InputDecorator) {
              doboz = a.findRenderObject();
              return false;
            }
            return a.widget is! EditableText && a.widget is! Form;
          });
          doboz ??= szoveg;
          if (szoveg is RenderBox && doboz is RenderBox) {
            final r = regi[el];
            if (r != null && identical(r.w, w) && identical(r.doboz, doboz)) {
              uj.add(r);
            } else {
              ModalRoute<dynamic>? route;
              try {
                route = ModalRoute.of(el);
              } catch (_) {}
              uj.add(_Mezo(el, w, doboz! as RenderBox, szoveg, route,
                  el.findAncestorStateOfType<AutofillGroupState>())
                ..input = r?.input);
            }
          }
        }
        return;
      }
      el.visitChildElements(bejar);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(bejar);
    // a régi, már nem létező mezők inputjai törlődnek
    for (final m in _mezok) {
      if (!uj.any((u) => identical(u.input, m.input))) m.input?.remove();
    }
    _mezok = uj;
  }

  // ---- egérmozgás ----

  void _mozgas() {
    if (_atadva != null) return;
    final host = _flutterView()?.getBoundingClientRect();
    final p = Offset(_px - (host?.left ?? 0), _py - (host?.top ?? 0));
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return;
    final talalat = HitTestResult();
    WidgetsBinding.instance
        .hitTestInView(talalat, p, views.first.flutterView.viewId);
    final ut = <Object>{for (final e in talalat.path) e.target};
    _gyujt(ut.any((t) => t is RenderEditable));
    if (_mezok.isEmpty) {
      _kikapcs();
      return;
    }
    _Mezo? alatta;
    for (final m in _mezok) {
      if (!m.el) continue;
      if (ut.contains(m.doboz) || ut.contains(m.szoveg)) {
        alatta = m;
        break;
      }
    }
    if (alatta == null ||
        !alatta.ures ||
        alatta.w.focusNode.hasFocus ||
        (alatta.route != null && !alatta.route!.isCurrent)) {
      _kikapcs();
      return;
    }
    if (!identical(alatta, _aktiv)) _bekapcs(alatta);
  }

  void _kikapcs() {
    final a = _aktiv;
    if (a == null) return;
    final i = a.input;
    if (i != null && identical(web.document.activeElement, i)) return;
    i?.style.pointerEvents = 'none';
    _aktiv = null;
  }

  void _bekapcs(_Mezo m) {
    // ha a böngésző épp kitöltött valamit, előbb az kerüljön át
    _kitoltesIdozito?.cancel();
    _kitoltes();
    _aktiv?.input?.style.pointerEvents = 'none';
    final form = _urlap();
    // a közös űrlapba az aktív oldal (és ugyanazon AutofillGroup) összes
    // kitölthető mezője bekerül, így a Chrome egy választással mindet kitölti
    final csoport = _mezok
        .where((x) =>
            x.el &&
            identical(x.route, m.route) &&
            identical(x.csoport, m.csoport))
        .toList();
    var i = 0;
    for (final x in csoport) {
      final inp = x.input ?? _ujInput(x);
      x.input = inp;
      inp.id = 'fpsaf-${i++}';
      if (inp.parentElement == null || !identical(inp.parentElement, form)) {
        form.append(inp);
      }
      _helyez(x);
      inp.style.pointerEvents = 'none';
    }
    // a más oldalakhoz tartozó szellemmezők kikerülnek az űrlapból
    for (final x in _mezok) {
      if (!csoport.contains(x)) x.input?.remove();
    }
    _aktiv = m;
    m.input?.style.pointerEvents = 'auto';
  }

  web.HTMLInputElement _ujInput(_Mezo m) {
    final inp = web.document.createElement('input') as web.HTMLInputElement;
    inp.className = 'fpsaf';
    final ac = _hintek[m.hint] ?? m.hint;
    inp.type = m.jelszo
        ? 'password'
        : (ac == 'email' ? 'email' : (ac.startsWith('tel') ? 'tel' : 'text'));
    inp.setAttribute('autocomplete', ac);
    inp.name = ac;
    inp.tabIndex = -1;
    inp.setAttribute('aria-hidden', 'true');
    inp.addEventListener(
        'beforeinput',
        ((web.Event e) {
          final ie = e as web.InputEvent;
          final t = ie.inputType;
          // a böngésző választásból kitöltése nem "gépelés"
          if (t == 'insertReplacementText') return;
          e.preventDefault();
          // Enter: nem gépelés (a Chrome-lista választása is lehet)
          if (t == 'insertLineBreak' || t == 'insertParagraph') return;
          var adat = ie.data;
          if (adat == null && t == 'insertFromPaste') {
            adat = ie.dataTransfer?.getData('text/plain');
          }
          _gepel(_mezoInputhoz(inp), t.startsWith('insert') ? (adat ?? '') : '');
        }).toJS);
    inp.addEventListener(
        'input',
        ((web.Event _) {
          _kitoltesIdozito?.cancel();
          _kitoltesIdozito =
              Timer(Duration.zero, _kitoltes);
        }).toJS);
    inp.addEventListener(
        'change',
        ((web.Event _) {
          _kitoltesIdozito?.cancel();
          _kitoltesIdozito =
              Timer(Duration.zero, _kitoltes);
        }).toJS);
    inp.addEventListener(
        'keydown',
        ((web.KeyboardEvent e) {
          if (e.key == 'Tab') {
            e.preventDefault();
            _gepel(_mezoInputhoz(inp), '', tab: e.shiftKey ? -1 : 1);
          }
        }).toJS);
    inp.addEventListener(
        'wheel',
        ((web.WheelEvent e) {
          // görgetés: a szellemmező félreáll, a görgetést a Flutter kapja
          inp.style.pointerEvents = 'none';
          if (identical(_aktiv?.input, inp)) _aktiv = null;
          final cel = web.document
              .elementFromPoint(e.clientX.toDouble(), e.clientY.toDouble());
          if (cel != null && !identical(cel, inp)) {
            e.preventDefault();
            cel.dispatchEvent(web.WheelEvent(
                'wheel',
                web.WheelEventInit(
                  bubbles: true,
                  cancelable: true,
                  clientX: e.clientX,
                  clientY: e.clientY,
                  screenX: e.screenX,
                  screenY: e.screenY,
                  deltaX: e.deltaX,
                  deltaY: e.deltaY,
                  deltaZ: e.deltaZ,
                  deltaMode: e.deltaMode,
                  ctrlKey: e.ctrlKey,
                  shiftKey: e.shiftKey,
                  altKey: e.altKey,
                  metaKey: e.metaKey,
                )));
          }
        }).toJS,
        web.AddEventListenerOptions(passive: false));
    inp.addEventListener(
        'blur',
        ((web.Event _) {
          if (!identical(_aktiv?.input, inp)) inp.style.pointerEvents = 'none';
          if (identical(_atadva?.input, inp)) _atadva = null;
        }).toJS);
    return inp;
  }

  _Mezo? _mezoInputhoz(web.HTMLInputElement inp) {
    for (final m in _mezok) {
      if (identical(m.input, inp)) return m;
    }
    return null;
  }

  void _helyez(_Mezo m) {
    final inp = m.input;
    if (inp == null || !m.el) return;
    final host = _flutterView()?.getBoundingClientRect();
    final hx = host?.left ?? 0, hy = host?.top ?? 0;
    final d = m.doboz.localToGlobal(Offset.zero) & m.doboz.size;
    final s = m.szoveg.localToGlobal(Offset.zero) & m.szoveg.size;
    final betu = (m.w.style.fontSize ?? 14).clamp(8, 40);
    final szin = m.w.cursorColor;
    final st = inp.style;
    st.left = '${d.left + hx}px';
    st.top = '${d.top + hy}px';
    st.width = '${d.width}px';
    st.height = '${d.height}px';
    st.paddingLeft = '${(s.left - d.left).clamp(0, d.width)}px';
    st.fontSize = '${betu}px';
    st.caretColor =
        'rgba(${(szin.r * 255).round()},${(szin.g * 255).round()},${(szin.b * 255).round()},1)';
  }

  /// Képkockánként: az aktív szellemmező követi a mezőt (görgetés, animáció).
  void _igazit() {
    final a = _aktiv;
    if (a == null) return;
    if (!a.el || !a.ures || a.w.focusNode.hasFocus) {
      _kikapcs();
      return;
    }
    _helyez(a);
  }

  // ---- gépelés: átadás a Flutter-mezőnek ----

  // A fókuszváltás előtt leütött karakterek: csak akkor írjuk a mezőbe, amikor
  // a Flutter-mező már megkapta a fókuszt (különben a mező bekapcsolásakor a
  // böngészős szerkesztő üresen indulhat, és felülírja őket).
  String _puffer = '';
  bool _fokuszKesz = false;

  void _beir(_Mezo m, String szoveg) {
    if (szoveg.isEmpty || !m.el) return;
    final c = m.w.controller;
    final uj = c.text + szoveg;
    c.value = TextEditingValue(
        text: uj, selection: TextSelection.collapsed(offset: uj.length));
    m.w.onChanged?.call(uj);
  }

  void _gepel(_Mezo? m, String szoveg, {int tab = 0}) {
    if (m == null || !m.el) return;
    if (identical(_atadva, m)) {
      // a fókusz már úton van ehhez a mezőhöz
      if (_fokuszKesz) {
        _beir(m, szoveg);
      } else {
        _puffer += szoveg;
      }
      return;
    }
    _atadva = m;
    _puffer = szoveg;
    _fokuszKesz = false;
    m.input?.style.pointerEvents = 'none';
    if (identical(_aktiv, m)) _aktiv = null;
    final fn = m.w.focusNode;
    var kesz = false;
    late final VoidCallback figyelo;
    void alkalmaz() {
      if (kesz) return;
      kesz = true;
      fn.removeListener(figyelo);
      // a kapcsolat megnyitása után (mikrotaszk) írjuk be a puffert
      scheduleMicrotask(() {
        _fokuszKesz = true;
        final p = _puffer;
        _puffer = '';
        _beir(m, p);
      });
    }

    figyelo = () {
      if (fn.hasFocus) alkalmaz();
    };
    fn.addListener(figyelo);
    Timer(const Duration(milliseconds: 400), alkalmaz);
    fn.requestFocus();
    if (tab != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (tab > 0) {
          m.w.focusNode.nextFocus();
        } else {
          m.w.focusNode.previousFocus();
        }
      });
    }
  }

  // ---- böngészős kitöltés: értékek a Flutter-mezőkbe ----

  void _kitoltes() {
    _Mezo? fokusz;
    for (final m in _mezok) {
      final inp = m.input;
      if (inp == null || !m.el) continue;
      final v = inp.value;
      if (v.isEmpty) continue;
      if (identical(_atadva, m)) continue;
      final c = m.w.controller;
      if (c.text != v) {
        c.value = TextEditingValue(
            text: v, selection: TextSelection.collapsed(offset: v.length));
        m.w.onChanged?.call(v);
      }
      inp.value = '';
      inp.style.pointerEvents = 'none';
      if (identical(web.document.activeElement, inp)) fokusz = m;
    }
    if (fokusz != null) {
      fokusz.input?.blur();
      _aktiv = null;
    }
  }
}
