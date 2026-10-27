// Calistir: dart bin/server.dart [port]   (proje klasorunde, once: flutter build web --release)
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class P {
  final WebSocket ws;
  final String name;
  int score = 0, i = 0;
  bool host = false;
  P(this.ws, this.name);
}

class Room {
  final String pw;
  final ps = <P>[];
  bool started = false;
  int next = 1;
  Room(this.pw);
}

final rooms = <String, Room>{};

void send(WebSocket w, Map m) => w.add(jsonEncode(m));

void bc(Room r) {
  final m = {
    't': 'players',
    'players': [for (final p in r.ps) {'name': p.name, 'score': p.score, 'i': p.i, 'host': p.host}]
  };
  for (final p in r.ps) send(p.ws, m);
}

// Oyuncunun yazdigi ad; bos ise "Oyuncu N", odada ayni ad varsa sonuna sayi eklenir.
String uniqueName(Room r, Object? raw) {
  var base = '${raw ?? ''}'.trim();
  if (base.length > 16) base = base.substring(0, 16);
  if (base.isEmpty) base = 'Oyuncu ${r.next++}';
  var n = base;
  var k = 2;
  while (r.ps.any((p) => p.name == n)) {
    n = '$base $k';
    k++;
  }
  return n;
}

void handle(WebSocket ws) {
  print('Yeni oyuncu baglandi');
  ws.pingInterval = const Duration(seconds: 30); // baglanti canli kalsin
  P? me;
  Room? rm;
  ws.listen((d) {
    final m = jsonDecode(d as String) as Map;
    switch (m['t']) {
      case 'create':
        final key = '${m['room']}'.trim().toLowerCase();
        if (key.isEmpty || rooms.containsKey(key)) {
          send(ws, {'t': 'err', 'msg': 'Bu oda adı kullanılıyor'});
          break;
        }
        final r1 = Room('${m['pass']}');
        rooms[key] = r1;
        rm = r1;
        me = P(ws, uniqueName(r1, m['name']))..host = true;
        r1.ps.add(me!);
        send(ws, {'t': 'joined', 'code': '${m['room']}'.trim(), 'host': true, 'you': me!.name});
        bc(r1);
      case 'join':
        final r2 = rooms['${m['room']}'.trim().toLowerCase()];
        if (r2 == null || r2.pw != '${m['pass']}') {
          send(ws, {'t': 'err', 'msg': 'Oda adı veya şifre yanlış'});
          break;
        }
        if (r2.started) {
          send(ws, {'t': 'err', 'msg': 'Oyun zaten başladı'});
          break;
        }
        rm = r2;
        me = P(ws, uniqueName(r2, m['name']));
        r2.ps.add(me!);
        send(ws, {'t': 'joined', 'code': '${m['room']}'.trim(), 'host': false, 'you': me!.name});
        bc(r2);
      case 'start':
        final r3 = rm;
        if (r3 == null || me?.host != true) break;
        r3.started = true;
        final seed = Random().nextInt(1 << 30);
        for (final p in r3.ps) {
          p.score = 0;
          p.i = 0;
          send(p.ws, {'t': 'start', 'seed': seed, 'levels': m['levels']});
        }
        bc(r3);
      case 'ev':
        // Oyun mesajlarini (soru, cevap, sonuc...) odadaki diger herkese ilet.
        final r5 = rm;
        final who = me;
        if (r5 == null || who == null) break;
        if (m['k'] == 'start') {
          if (!who.host) break; // oyunu sadece oda sahibi baslatabilir
          r5.started = true; // oyun sirasinda yeni oyuncu katilamasin
        }
        final out = {...m, 'from': who.name};
        for (final p in r5.ps) {
          if (p != who) send(p.ws, out);
        }
      case 'score':
        me?.score = m['score'] as int;
        me?.i = m['i'] as int;
        final r4 = rm;
        if (r4 != null) bc(r4);
    }
  }, onDone: () {
    final r = rm;
    if (r == null) return;
    r.ps.remove(me);
    if (r.ps.isEmpty) {
      rooms.removeWhere((k, v) => v == r);
    } else {
      if (!r.ps.any((p) => p.host)) r.ps.first.host = true;
      bc(r);
    }
  });
}

const types = {
  'html': 'text/html; charset=utf-8', 'js': 'application/javascript', 'css': 'text/css',
  'json': 'application/json', 'png': 'image/png', 'ico': 'image/x-icon',
  'wasm': 'application/wasm', 'otf': 'font/otf', 'ttf': 'font/ttf',
};

Future<void> serve(HttpRequest req) async {
  final p = req.uri.path == '/' ? '/index.html' : req.uri.path;
  final f = File('build/web$p');
  if (p.contains('..') || !await f.exists()) {
    req.response.statusCode = 404;
    await req.response.close();
    return;
  }
  req.response.headers.contentType =
      ContentType.parse(types[p.split('.').last] ?? 'application/octet-stream');
  await f.openRead().pipe(req.response);
}

Future<void> main(List<String> args) async {
  // Bulutta port PORT degiskeninden gelir; bilgisayarda 8080.
  final port = args.isNotEmpty ? int.parse(args[0]) : int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  try {
    // Ayni Wi-Fi'daki telefonlar sunucuyu bu yayinla otomatik bulur.
    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8081);
    udp.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = udp.receive();
      if (d != null && utf8.decode(d.data, allowMalformed: true) == 'BILTEAC?') {
        udp.send(utf8.encode('BILTEAC:$port'), d.address, d.port);
      }
    });
  } catch (_) {
    print('Uyari: otomatik bulma (UDP 8081) acilamadi.');
  }
  print('Bilteac sunucusu calisiyor. Digerleri tarayicidan su adreslerden girebilir:');
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in ni.addresses) {
      if (!a.isLoopback) print('  http://${a.address}:$port');
    }
  }
  await for (final req in server) {
    try {
      if (req.uri.path == '/ws') {
        handle(await WebSocketTransformer.upgrade(req));
      } else {
        await serve(req);
      }
    } catch (e) {
      print('Hata: $e');
    }
  }
}
