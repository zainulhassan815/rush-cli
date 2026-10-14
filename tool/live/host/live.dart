import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const usage = '''
rush live: run an extension on a phone and drive its blocks from here.

  live [up]                          Watch, reload on save, serve the panel. Long-running.
  live status                        Device, app and session state.
  live blocks [Type]                 The extension's blocks, with types and options.
  live create <Type> <name>          Create a component (extension or built-in, e.g. VerticalArrangement).
  live call <name> <Method> [args]   Call a method. --wait <Event>[=<value>] [--timeout <s>] waits for it.
  live get <name> <Property>         Read a property.
  live set <name> <Property> <value> Set a property.
  live events [--since <cursor>] [--wait <Event>[=<value>]] [--timeout <s>]
  live reload                        Build, push and restart with the session replayed.
  live restart                       Restart and replay without building.
  live remove <name>                 Remove a component and every step that uses it, then restart.
  live session [clear | remove <n>]  The steps replayed after every restart.
  live screenshot [file]             Save a screenshot of the phone.

Every command except up prints one JSON object. Exit codes: 0 ok, 1 failed, 2 usage, 3 no device or app.
Arguments are strings; lists and dictionaries are JSON. create, set and calls without a result are
recorded in live.jsonl and replayed after every reload, so the app comes back in the same state.
''';

const panelPort = 7465;
const appPackage = 'dev.rush.live.app';
const commandAction = 'dev.rush.live.COMMAND';
const remoteDir = '/sdcard/Android/data/$appPackage/files/live';

Future<void> main(List<String> args) async {
  try {
    exitCode = await Cli(args).run();
  } on LiveFailure catch (failure) {
    if (args.isEmpty || args.first == 'up') {
      stderr.writeln('${failure.type}: ${failure.message}');
    } else {
      stdout.writeln(jsonEncode(failure.toJson()));
    }
    exitCode = failure.exitCode;
  }
}

class LiveFailure implements Exception {
  LiveFailure(
    this.type,
    this.message, {
    this.exitCode = 1,
    this.details = const {},
  });

  LiveFailure.usage(String message) : this('Usage', message, exitCode: 2);

  LiveFailure.unavailable(
    String type,
    String message, {
    Map<String, Object?> details = const {},
  }) : this(type, message, exitCode: 3, details: details);

  final String type;
  final String message;
  final int exitCode;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
        'ok': false,
        'error': {'type': type, 'message': message, ...details},
      };
}

class Cli {
  Cli(this.args);

  final List<String> args;

  Future<int> run() async {
    final command = args.isEmpty ? 'up' : args.first;
    final rest = args.skip(1).toList();
    if (command == 'help' || command == '--help' || command == '-h') {
      stdout.write(usage);
      return 0;
    }
    final project = Project.find(Directory.current);
    if (command == 'blocks') {
      return emit({
        'ok': true,
        'components': project.metadata.describe(rest.firstOrNull),
      });
    }
    if (command == 'session') {
      return emit(sessionCommand(project.session, rest));
    }
    final live = Live(project, await Device.connect());
    switch (command) {
      case 'up':
        await Up(live).run();
        return 0;
      case 'status':
        return emit(await live.status());
      case 'create':
        return emit(
          await live.perform(
            'create',
            requireArgs(rest, 2, 'create <Type> <name>'),
          ),
        );
      case 'get':
        return emit(
          await live.perform(
            'get',
            requireArgs(rest, 2, 'get <name> <Property>'),
          ),
        );
      case 'set':
        return emit(
          await live.perform(
            'set',
            requireArgs(rest, 3, 'set <name> <Property> <value>'),
          ),
        );
      case 'call':
        return emit(await call(live, rest));
      case 'events':
        return emit(await events(live, rest));
      case 'reload':
        return emit(await Panel.forward('reload') ?? await live.reload());
      case 'restart':
        return emit(await live.restart());
      case 'remove':
        return emit(
          await live.remove(requireArgs(rest, 1, 'remove <name>').first),
        );
      case 'screenshot':
        return emit(await live.screenshot(rest.firstOrNull));
      default:
        throw LiveFailure.usage('Unknown command $command. Run live help.');
    }
  }

  Future<Map<String, Object?>> call(Live live, List<String> rest) async {
    final options = Options.parse(rest, ['wait', 'timeout']);
    final callArgs = requireArgs(
      options.positional,
      2,
      'call <name> <Method> [args] [--wait <Event>]',
    );
    final response = await live.perform('call', callArgs);
    final waitFor = options.values['wait'];
    if (waitFor == null || response['ok'] != true) {
      return response;
    }
    final event = await live.waitForEvent(
      waitFor,
      response['cursor'] as int,
      options.timeout,
    );
    return {...response, 'event': event};
  }

  Future<Map<String, Object?>> events(Live live, List<String> rest) async {
    final options = Options.parse(rest, ['since', 'wait', 'timeout']);
    final since = int.tryParse(options.values['since'] ?? '') ?? 0;
    final waitFor = options.values['wait'];
    if (waitFor != null) {
      final cursor = since == 0 ? (await live.events(0))['last'] as int : since;
      return {
        'ok': true,
        'event': await live.waitForEvent(waitFor, cursor, options.timeout),
      };
    }
    return {'ok': true, ...await live.events(since)};
  }

  Map<String, Object?> sessionCommand(Session session, List<String> rest) {
    switch (rest.firstOrNull) {
      case null:
        break;
      case 'clear':
        session.clear();
      case 'remove':
        final index = int.tryParse(rest.elementAtOrNull(1) ?? '');
        if (index == null || index < 1 || index > session.steps.length) {
          throw LiveFailure.usage(
            'session remove <n> takes a step number from 1 to ${session.steps.length}',
          );
        }
        session.removeAt(index - 1);
      default:
        throw LiveFailure.usage('session [clear | remove <n>]');
    }
    return {'ok': true, 'steps': session.steps};
  }

  List<String> requireArgs(List<String> args, int count, String form) {
    if (args.length < count) {
      throw LiveFailure.usage('Expected: live $form');
    }
    return args;
  }

  int emit(Map<String, Object?> result) {
    stdout.writeln(jsonEncode(result));
    return result['ok'] == true ? 0 : 1;
  }
}

class Options {
  Options(this.positional, this.values);

  factory Options.parse(List<String> args, List<String> names) {
    final positional = <String>[];
    final values = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final name = args[i].startsWith('--') ? args[i].substring(2) : null;
      if (name != null && names.contains(name)) {
        if (i + 1 >= args.length) {
          throw LiveFailure.usage('--$name needs a value');
        }
        values[name] = args[++i];
      } else {
        positional.add(args[i]);
      }
    }
    return Options(positional, values);
  }

  final List<String> positional;
  final Map<String, String> values;

  Duration get timeout => Duration(
        milliseconds: (double.parse(values['timeout'] ?? '10') * 1000).round(),
      );
}

class Toolchain {
  static final home = File.fromUri(Platform.script).parent.parent;
  static final userHome = Platform.environment['HOME']!;
  static final e2eCache =
      Platform.environment['RUSH_E2E_CACHE'] ?? '$userHome/.cache/rush-e2e';
  static final rushHome =
      Platform.environment['RUSH_HOME'] ?? '$userHome/.rush';
  static final androidHome =
      Platform.environment['ANDROID_HOME'] ?? '$userHome/Android/sdk';
  static final companionAix = File(
    '${home.path}/companion/out/dev.rush.live.aix',
  );
  static final projectGenerator = File('${home.path}/liveproject.py');
  static final keystore = File('${home.path}/android.keystore');
  static final panelPage = File('${home.path}/host/panel.html');
  static final builtInComponents = File(
    '$e2eCache/appinventor-v206/appinventor/build/components/simple_components.json',
  );
  static final buildServerScript = File(
    '${home.parent.path}/e2e/buildserver.sh',
  );
  static final androidJar = File('$rushHome/ai2/v206/libs/android.jar');
  static final adb =
      Platform.environment['ADB'] ?? '$androidHome/platform-tools/adb';

  static String get java11 =>
      Platform.environment['JAVA11_HOME'] ??
      Directory('$userHome/.sdkman/candidates/java')
          .listSync()
          .map((e) => e.path)
          .firstWhere(
            (path) => path.split('/').last.startsWith('11'),
            orElse: () => throw LiveFailure(
              'MissingJdk',
              'JDK 11 is needed to build the dev app',
            ),
          );

  static String get d8Jar {
    final jars = Directory('$userHome/.m2/repository/com/android/tools/r8')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => RegExp(r'r8-[\d.]+\.jar$').hasMatch(file.path))
        .map((file) => file.path)
        .toList()
      ..sort();
    if (jars.isEmpty) {
      throw LiveFailure('MissingD8', 'No R8 jar in ~/.m2: run rush build once');
    }
    return jars.last;
  }
}

Future<String> check(
  String executable,
  List<String> arguments, {
  String? cwd,
  String failure = 'ToolFailed',
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
  );
  if (result.exitCode != 0) {
    final output = '${result.stdout}${result.stderr}'.trim().split('\n');
    throw LiveFailure(
      failure,
      '${executable.split('/').last} ${arguments.firstOrNull ?? ''} failed',
      details: {
        'output':
            output.skip(output.length > 20 ? output.length - 20 : 0).join('\n'),
      },
    );
  }
  return result.stdout as String;
}

class Project {
  Project(this.root, this.session);

  static Project find(Directory start) {
    for (Directory dir = start.absolute;; dir = dir.parent) {
      if (File('${dir.path}/rush.yml').existsSync()) {
        return Project(dir, Session(File('${dir.path}/live.jsonl')));
      }
      if (dir.parent.path == dir.path) {
        throw LiveFailure.usage(
          'Not in a Rush project: no rush.yml here or above',
        );
      }
    }
  }

  final Directory root;
  final Session session;

  Directory get work => Directory('${root.path}/.rush/live');

  File get aix {
    final out = Directory('${root.path}/out');
    final aixes = out.existsSync()
        ? out.listSync().whereType<File>().where((f) => f.path.endsWith('.aix'))
        : <File>[];
    if (aixes.isEmpty) {
      throw LiveFailure(
        'NotBuilt',
        'No AIX in out/: run rush build or live reload',
      );
    }
    return aixes.first;
  }

  Metadata get metadata => Metadata.fromAix(aix);
}

class Metadata {
  Metadata(this.components, this.builtIns);

  factory Metadata.fromAix(File aix) {
    final listing = Process.runSync(
        'unzip',
        [
          '-p',
          aix.path,
          '*/components.json',
        ],
        stdoutEncoding: utf8);
    final builtIns =
        (jsonDecode(Toolchain.builtInComponents.readAsStringSync()) as List)
            .cast<Map<String, dynamic>>()
            .where(
              (component) =>
                  component['name'] != 'Form' &&
                  component['showOnPalette'] == 'true',
            )
            .toList();
    return Metadata(
      (jsonDecode(listing.stdout as String) as List)
          .cast<Map<String, dynamic>>(),
      builtIns,
    );
  }

  static final componentName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

  final List<Map<String, dynamic>> components;
  final List<Map<String, dynamic>> builtIns;

  Iterable<Map<String, dynamic>> get all => [...components, ...builtIns];

  Map<String, dynamic>? component(String type) =>
      all.where((c) => c['name'] == type).firstOrNull;

  void checkCreate(String type, String name) {
    if (component(type) == null) {
      throw invalid(
        '$type is not a component of the extension or App Inventor',
        suggest(type, all.toList()),
      );
    }
    if (!componentName.hasMatch(name) || name == 'Screen1') {
      throw invalid(
        '$name is not a valid component name: use letters, digits and _, starting with a letter',
      );
    }
  }

  bool returnsValue(String type, String method) {
    final methods = (component(type)?['methods'] as List?) ?? const [];
    return methods.any((m) => m['name'] == method && m['returnType'] != null);
  }

  List<String> eventParams(String type, String event) {
    final events = (component(type)?['events'] as List?) ?? const [];
    final match = events.where((e) => e['name'] == event).firstOrNull;
    return [
      for (final param in (match?['params'] as List?) ?? const [])
        param['name'] as String,
    ];
  }

  List<Object?> check(String type, String verb, List<Object?> args) {
    final component = this.component(type);
    if (component == null) return args;
    final block = '${args[1]}';
    final given = args.skip(2).toList();
    if (verb == 'call') {
      final method = (component['methods'] as List)
          .where((m) => m['name'] == block)
          .firstOrNull;
      if (method == null) {
        throw invalid(
          '$type has no method $block',
          suggest(block, component['methods'] as List),
        );
      }
      final params = (method['params'] as List).cast<Map<String, dynamic>>();
      if (params.length != given.length) {
        throw invalid(
          '$block takes ${params.length} arguments: $block(${params.map(signature).join(', ')})',
        );
      }
      return [
        args[0],
        block,
        for (var i = 0; i < params.length; i++) convert(params[i], given[i]),
      ];
    }
    final property = (component['blockProperties'] as List)
        .where((p) => p['name'] == block)
        .firstOrNull;
    if (property == null) {
      throw invalid(
        '$type has no property $block',
        suggest(block, component['blockProperties'] as List),
      );
    }
    if (verb == 'get' && property['rw'] == 'write-only') {
      throw invalid('$block can only be set');
    }
    if (verb == 'set' && property['rw'] == 'read-only') {
      throw invalid('$block is read-only');
    }
    if (verb == 'get') return [args[0], block];
    if (given.length != 1) throw invalid('set $block takes one value');
    return [
      args[0],
      block,
      convert({...property, 'name': block}, given.single),
    ];
  }

  Object? convert(Map<String, dynamic> param, Object? value) {
    final text = '$value';
    final options = [
      for (final option
          in (param['helper']?['data']?['options'] as List?) ?? const [])
        '${option['value']}',
    ];
    if (options.isNotEmpty) {
      final match = options
          .where((option) => option.toLowerCase() == text.toLowerCase())
          .firstOrNull;
      return match ??
          (throw invalid(
            '${param['name']} must be one of ${options.join(', ')}, not $text',
          ));
    }
    switch (param['type']) {
      case 'number':
        return value is num
            ? value
            : num.tryParse(text) ??
                (throw invalid(
                  '${param['name']} must be a number, not $text',
                ));
      case 'boolean':
        if (value is bool) return value;
        if (text == 'true' || text == 'false') return text == 'true';
        throw invalid('${param['name']} must be true or false, not $text');
      case 'list' || 'dictionary':
        if (value is! String) return value;
        try {
          return jsonDecode(text);
        } on FormatException {
          throw invalid(
            '${param['name']} must be JSON ${param['type'] == 'list' ? 'like [1, 2]' : 'like {"key": "value"}'}',
          );
        }
      default:
        return value;
    }
  }

  String signature(Map<String, dynamic> param) =>
      '${param['name']}: ${param['type']}';

  List<String> suggest(String wanted, List<dynamic> blocks) {
    final names = [for (final block in blocks) block['name'] as String];
    final ranked = names
        .map(
          (name) => (name, distance(name.toLowerCase(), wanted.toLowerCase())),
        )
        .toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    return [
      for (final (name, score) in ranked.take(3))
        if (score <= 4 || name.toLowerCase().contains(wanted.toLowerCase()))
          name,
    ];
  }

  int distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = [i, ...List<int>.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      previous = current;
    }
    return previous[b.length];
  }

  LiveFailure invalid(String message, [List<String> suggestions = const []]) =>
      LiveFailure(
        'InvalidBlock',
        message,
        details: {if (suggestions.isNotEmpty) 'didYouMean': suggestions},
      );

  String eventSignature() => [
        for (final component in components)
          for (final event in component['events'] as List)
            '${component['name']}.${event['name']}(${[
              for (final p in event['params']) p['name']
            ].join(',')})',
      ].join(';');

  List<Map<String, Object?>> describe(String? type) => [
        for (final component in type == null ? components : all)
          if (type == null || component['name'] == type)
            {
              'type': component['name'],
              'description': component['helpString'],
              'methods': [
                for (final method in component['methods'] as List)
                  {
                    'name': method['name'],
                    'params': [
                      for (final param in method['params'])
                        describeValue(param),
                    ],
                    if (method['returnType'] != null)
                      'returns': method['returnType'],
                    'description': method['description'],
                  },
              ],
              'properties': [
                for (final property in component['blockProperties'] as List)
                  {
                    ...describeValue(property),
                    'access': property['rw'],
                    'description': property['description'],
                  },
              ],
              'events': [
                for (final event in component['events'] as List)
                  {
                    'name': event['name'],
                    'params': [
                      for (final param in event['params']) describeValue(param),
                    ],
                    'description': event['description'],
                  },
              ],
            },
      ];

  Map<String, Object?> describeValue(Map<String, dynamic> value) {
    final options = value['helper']?['data']?['options'] as List?;
    return {
      'name': value['name'],
      'type': value['type'],
      if (options != null)
        'options': [for (final option in options) option['value']],
    };
  }
}

class Session {
  Session(this.file);

  final File file;

  List<Map<String, dynamic>> get steps => file.existsSync()
      ? [
          for (final line in file.readAsLinesSync())
            if (line.trim().isNotEmpty)
              jsonDecode(line) as Map<String, dynamic>,
        ]
      : [];

  String? typeOf(String name) => steps
      .where(
        (step) => step['verb'] == 'create' && (step['args'] as List)[1] == name,
      )
      .map((step) => (step['args'] as List)[0] as String)
      .firstOrNull;

  void record(String verb, String command, List<Object?> args) =>
      file.writeAsStringSync(
        '${jsonEncode({'verb': verb, 'command': command, 'args': args})}\n',
        mode: FileMode.append,
      );

  void removeAt(int index) => write(steps..removeAt(index));

  void clear() => write([]);

  void write(List<Map<String, dynamic>> steps) => file.writeAsStringSync(
        steps.map((step) => '${jsonEncode(step)}\n').join(),
      );
}

class Device {
  Device(this.serial);

  static Future<Device> connect() async {
    final result = await Process.run(Toolchain.adb, ['devices']);
    if (result.exitCode != 0) {
      throw LiveFailure.unavailable(
        'NoAdb',
        'adb is not available at ${Toolchain.adb}',
      );
    }
    final devices = [
      for (final line in (result.stdout as String).split('\n').skip(1))
        if (line.trim().endsWith('\tdevice')) line.split('\t').first,
    ];
    final wanted = Platform.environment['ANDROID_SERIAL'];
    if (wanted != null) {
      if (!devices.contains(wanted)) {
        throw LiveFailure.unavailable(
          'NoDevice',
          'ANDROID_SERIAL=$wanted is not connected',
        );
      }
      return Device(wanted);
    }
    if (devices.isEmpty) {
      throw LiveFailure.unavailable(
        'NoDevice',
        'No phone connected: plug one in with USB debugging on',
      );
    }
    if (devices.length > 1) {
      throw LiveFailure.unavailable(
        'SeveralDevices',
        'Several phones connected (${devices.join(', ')}): set ANDROID_SERIAL',
      );
    }
    return Device(devices.single);
  }

  final String serial;

  Future<String> adb(List<String> args, {String failure = 'AdbFailed'}) =>
      check(Toolchain.adb, ['-s', serial, ...args], failure: failure);

  Future<Map<String, dynamic>> request(
    String command, [
    List<Object?> args = const [],
  ]) async {
    final request = base64.encode(
      utf8.encode(jsonEncode({'command': command, 'args': args})),
    );
    final reply = await broadcast(request) ??
        await bringToFront().then((_) => broadcast(request));
    if (reply == null) {
      throw LiveFailure.unavailable(
        'AppNotRunning',
        'The dev app is not running: run live restart',
        details: {'crash': await crash()},
      );
    }
    return jsonDecode(reply) as Map<String, dynamic>;
  }

  Future<String?> broadcast(String request) async {
    final output = await adb([
      'shell',
      'am',
      'broadcast',
      '-a',
      commandAction,
      '-p',
      appPackage,
      '--es',
      'request',
      request,
    ]);
    return RegExp(
      r'data="(.*)"\s*$',
      dotAll: true,
    ).firstMatch(output.trim())?.group(1);
  }

  Future<void> bringToFront() async {
    final running = await Process.run(Toolchain.adb, [
      '-s',
      serial,
      'shell',
      'pidof',
      appPackage,
    ]);
    if ('${running.stdout}'.trim().isNotEmpty) {
      await wake();
      await adb(['shell', 'am', 'start', '-W', '-n', '$appPackage/.Screen1']);
    }
  }

  Future<void> wake() async {
    await adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
    await adb(['shell', 'wm', 'dismiss-keyguard']);
  }

  Future<Object?> crash() async {
    final report = await Process.run(Toolchain.adb, [
      '-s',
      serial,
      'shell',
      'cat',
      '$remoteDir/crash.json',
    ]);
    return report.exitCode == 0 ? jsonDecode('${report.stdout}') : null;
  }

  Future<String> model() async =>
      (await adb(['shell', 'getprop', 'ro.product.model'])).trim();

  Future<Map<String, bool>> screen() async {
    final power = await adb(['shell', 'dumpsys', 'power']);
    final window = await adb(['shell', 'dumpsys', 'window']);
    return {
      'awake': power.contains('mWakefulness=Awake'),
      'locked': window.contains('isKeyguardShowing=true') ||
          window.contains('mShowingLockscreen=true'),
    };
  }

  Future<bool> installed() async => (await Process.run(Toolchain.adb, [
        '-s',
        serial,
        'shell',
        'pm',
        'path',
        appPackage,
      ]))
          .stdout
          .toString()
          .isNotEmpty;

  Future<void> install(File apk) async {
    final result = await Process.run(Toolchain.adb, [
      '-s',
      serial,
      'install',
      '-r',
      apk.path,
    ]);
    if (result.exitCode == 0) {
      return;
    }
    if ('${result.stdout}${result.stderr}'.contains(
      'INSTALL_FAILED_UPDATE_INCOMPATIBLE',
    )) {
      await adb(['uninstall', appPackage]);
      await adb(['install', apk.path], failure: 'InstallFailed');
      return;
    }
    throw LiveFailure(
      'InstallFailed',
      '${result.stdout}${result.stderr}'.trim(),
    );
  }

  Future<void> push(List<File> files) async {
    await adb(['shell', 'mkdir', '-p', remoteDir]);
    await adb(['push', ...files.map((file) => file.path), '$remoteDir/']);
  }

  Future<void> launch() async {
    await wake();
    await adb(['shell', 'am', 'force-stop', appPackage]);
    await adb(['shell', 'am', 'start', '-W', '-n', '$appPackage/.Screen1']);
  }

  Future<void> screenshot(File target) async {
    final capture = await Process.start(Toolchain.adb, [
      '-s',
      serial,
      'exec-out',
      'screencap',
      '-p',
    ]);
    await capture.stdout.pipe(target.openWrite());
    if (await capture.exitCode != 0) {
      throw LiveFailure('ScreenshotFailed', 'screencap failed');
    }
  }
}

class Live {
  Live(this.project, this.device);

  final Project project;
  final Device device;
  final phase = StreamController<String>.broadcast();
  String currentPhase = 'idle';

  Directory get work => project.work;

  void enter(String name) {
    currentPhase = name;
    phase.add(name);
  }

  Future<Map<String, Object?>> perform(
    String verb,
    List<Object?> rawArgs,
  ) async {
    final name = '${rawArgs[0]}';
    final command = verb == 'create' ? 'create' : 'call';
    final metadata = project.metadata;
    if (verb == 'create') {
      metadata.checkCreate('${rawArgs[0]}', '${rawArgs[1]}');
    }
    final type = verb == 'create' ? null : project.session.typeOf(name);
    final args = type == null ? rawArgs : metadata.check(type, verb, rawArgs);
    final response = await request(command, args);
    final result = response['result'];
    final created = result is! Map || result['created'] != false;
    if (response['ok'] == true && created && records(verb, name, args)) {
      project.session.record(verb, command, args);
    }
    return response;
  }

  Future<Map<String, dynamic>> request(
    String command, [
    List<Object?> args = const [],
  ]) async {
    try {
      return await device.request(command, args);
    } on LiveFailure catch (failure) {
      final removed = dropCrashedStep(failure.details['crash']);
      if (removed == null) rethrow;
      throw LiveFailure.unavailable(
        failure.type,
        'The app crashed. Run live restart.',
        details: {...failure.details, 'removedFromSession': removed},
      );
    }
  }

  Map<String, dynamic>? dropCrashedStep(Object? crash) {
    final after = crash is Map ? crash['after'] : null;
    if (after is! Map) return null;
    final steps = project.session.steps;
    final index = steps.lastIndexWhere(
      (step) =>
          step['command'] == after['command'] &&
          jsonEncode(step['args']) == jsonEncode(after['args']),
    );
    if (index == -1) return null;
    project.session.removeAt(index);
    return steps[index];
  }

  bool records(String verb, String name, List<Object?> args) => switch (verb) {
        'create' || 'set' => true,
        'call' => !project.metadata.returnsValue(
            project.session.typeOf(name) ?? '',
            '${args[1]}',
          ),
        _ => false,
      };

  Future<Map<String, Object?>> events(int since) async {
    final response = await request('events', [since]);
    final result = response['result'] as Map<String, dynamic>;
    return {
      'last': result['last'],
      'events': [for (final event in result['events'] as List) named(event)],
    };
  }

  Map<String, Object?> named(Map<String, dynamic> event) {
    final type = project.session.typeOf(event['component'] as String) ?? '';
    final params = project.metadata.eventParams(type, event['event'] as String);
    final args = event['args'] as List;
    return {
      ...event,
      if (params.length == args.length)
        'named': {for (var i = 0; i < args.length; i++) params[i]: args[i]},
    };
  }

  Future<Map<String, Object?>> waitForEvent(
    String wanted,
    int since,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var cursor = since;
    while (DateTime.now().isBefore(deadline)) {
      final batch = await events(cursor);
      cursor = batch['last'] as int;
      for (final event in batch['events'] as List) {
        if (matches(event as Map<String, Object?>, wanted)) {
          return event;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw LiveFailure(
      'Timeout',
      'No $wanted event within ${timeout.inMilliseconds / 1000}s',
      details: {'cursor': cursor},
    );
  }

  bool matches(Map<String, Object?> event, String wanted) {
    final [name, ...value] = wanted.split('=');
    final named = name == event['event'] ||
        name == '${event['component']}.${event['event']}';
    return named &&
        (value.isEmpty ||
            (event['args'] as List).any((arg) => '$arg' == value.join('=')));
  }

  Future<Map<String, Object?>> status() async {
    final screen = await device.screen();
    final installed = await device.installed();
    Map<String, dynamic>? app;
    if (installed) {
      try {
        app = (await request('status'))['result'] as Map<String, dynamic>;
      } on LiveFailure catch (failure) {
        if (failure.type != 'AppNotRunning') rethrow;
      }
    }
    final pushed = File('${work.path}/push/stamp');
    return {
      'ok': true,
      'device': {
        'serial': device.serial,
        'model': await device.model(),
        ...screen,
      },
      'app': {
        'installed': installed,
        'running': app != null,
        if (app != null) ...app,
        if (app != null && pushed.existsSync())
          'upToDate': app['loaded'] == pushed.readAsStringSync().trim(),
      },
      'session': project.session.steps.length,
      if (await Panel.running()) 'panel': 'http://127.0.0.1:$panelPort',
    };
  }

  Future<Map<String, Object?>> reload({bool rebuildApp = false}) async {
    final timings = <String, int>{};
    Future<T> timed<T>(String name, Future<T> Function() step) async {
      enter(name);
      final watch = Stopwatch()..start();
      final result = await step();
      timings[name] = watch.elapsedMilliseconds;
      return result;
    }

    final build = await timed('building', () => RushBuild(project.root).run());
    if (!build.ok) {
      enter('failed');
      return {
        'ok': false,
        'error': {
          'type': 'BuildFailed',
          'message': 'rush build failed',
          'errors': build.errors,
        },
        'ms': timings,
      };
    }
    final staged = await timed(
      'staging',
      () => Staged.from(project.aix, Directory('${work.path}/push')),
    );
    if (rebuildApp ||
        !await device.installed() ||
        !staged.matchesDevApp(work)) {
      final apk = await timed(
        'building dev app',
        () => DevApp(work).build(staged),
      );
      await timed('installing', () => device.install(apk));
      staged.rememberDevApp(work);
    }
    await timed('pushing', () async {
      await staged.dex();
      await device.push(staged.files);
    });
    final ready = await timed('restarting', () => waitReady(staged.stamp));
    enter('ready');
    return {'ok': true, 'ms': timings, ...ready};
  }

  Future<Map<String, Object?>> remove(String name) async {
    bool uses(Map<String, dynamic> step) {
      final args = step['args'] as List;
      return step['verb'] == 'create' ? args[1] == name : args.contains(name);
    }

    final steps = project.session.steps;
    final removed = steps.where(uses).toList();
    if (removed.isEmpty) {
      throw LiveFailure(
        'InvalidBlock',
        'No component named $name in the session',
      );
    }
    project.session.write(steps.where((step) => !uses(step)).toList());
    return {...await restart(), 'removedSteps': removed};
  }

  Future<Map<String, Object?>> restart() async {
    final stamp = File('${work.path}/push/stamp');
    final ready = await waitReady(
      stamp.existsSync() ? stamp.readAsStringSync().trim() : '',
    );
    enter('ready');
    return {'ok': true, ...ready};
  }

  File sessionCopy() {
    final copy = File('${work.path}/push/session.jsonl')
      ..createSync(recursive: true);
    return copy
      ..writeAsStringSync(
        project.session.file.existsSync()
            ? project.session.file.readAsStringSync()
            : '',
      );
  }

  Future<Map<String, Object?>> waitReady(String stamp) async {
    final removed = <Map<String, dynamic>>[];
    await device.push([sessionCopy()]);
    await device.launch();
    final started = DateTime.now();
    while (DateTime.now().difference(started) < const Duration(seconds: 60)) {
      try {
        final status =
            (await device.request('status'))['result'] as Map<String, dynamic>;
        if (status['ready'] == true && status['loaded'] == stamp) {
          return {
            'replayed': status['replayed'],
            'replayFailures': status['replayFailures'],
            'previousCrash': status['previousCrash'],
            if (removed.isNotEmpty) 'removedFromSession': removed,
          };
        }
      } on LiveFailure catch (failure) {
        if (failure.type != 'AppNotRunning') rethrow;
        final step = dropCrashedStep(failure.details['crash']);
        if (step != null && removed.length < 3) {
          removed.add(step);
          await device.push([sessionCopy()]);
          await device.launch();
        }
      }
      if (DateTime.now().difference(started) > const Duration(seconds: 3)) {
        final screen = await device.screen();
        if (!screen['awake']! || screen['locked']!) {
          enter('waiting for unlock');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw LiveFailure(
      'NotReady',
      'The dev app did not start within 60s. Is the phone unlocked?',
      details: {if (removed.isNotEmpty) 'removedFromSession': removed},
    );
  }

  Future<Map<String, Object?>> screenshot(String? path) async {
    final target = File(path ?? '${work.path}/screenshot.png')
      ..parent.createSync(recursive: true);
    await device.screenshot(target);
    return {'ok': true, 'path': target.absolute.path};
  }
}

class RushBuild {
  RushBuild(this.project);

  final Directory project;

  Future<({bool ok, List<String> errors})> run() async {
    final result = await Process.run(
        'rush',
        [
          '--no-color',
          'build',
        ],
        workingDirectory: project.path);
    final lines = '${result.stdout}${result.stderr}'
        .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
        .split('\n');
    final errors = <String>[];
    for (final line in lines) {
      final text = line.replaceFirst(RegExp(r'^[│┌└•\s]+'), '');
      if (text.startsWith('error ')) {
        errors.add(text.substring(6).trim());
      } else if (errors.isNotEmpty &&
          line.startsWith('│ ') &&
          line.length > 8 &&
          line[2] == ' ') {
        errors[errors.length - 1] = '${errors.last}\n${line.substring(8)}';
      }
    }
    const shown = 10;
    return (
      ok: result.exitCode == 0,
      errors: errors.length <= shown
          ? errors
          : [...errors.take(shown), '${errors.length - shown} more errors'],
    );
  }
}

class Staged {
  Staged(this.aix, this.dir, this.stamp);

  static Future<Staged> from(File aix, Directory dir) async {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    final unpacked = Directory('${dir.path}/aix')..createSync(recursive: true);
    await check('unzip', ['-q', aix.path, '-d', unpacked.path]);
    final runtime = unpacked
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) => f.path.endsWith('/files/AndroidRuntime.jar'));
    final stamp = (await check('sha256sum', [runtime.path])).split(' ').first;
    File('${dir.path}/stamp').writeAsStringSync(stamp);
    final components = unpacked
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) => f.path.endsWith('/components.json'));
    components.copySync('${dir.path}/components.json');
    return Staged(aix, dir, stamp);
  }

  final File aix;
  final Directory dir;
  final String stamp;

  File get runtime => Directory('${dir.path}/aix')
      .listSync(recursive: true)
      .whereType<File>()
      .firstWhere((f) => f.path.endsWith('/files/AndroidRuntime.jar'));

  List<File> get files => [
        File('${dir.path}/classes.jar'),
        File('${dir.path}/components.json'),
        File('${dir.path}/stamp'),
      ];

  Future<void> dex() => check(
      'java',
      [
        '-cp',
        Toolchain.d8Jar,
        'com.android.tools.r8.D8',
        '--release',
        '--no-desugaring',
        '--min-api',
        '21',
        '--lib',
        Toolchain.androidJar.path,
        '--output',
        '${dir.path}/classes.jar',
        runtime.path,
      ],
      failure: 'DexFailed');

  String devAppKey() {
    final unpacked = Directory('${dir.path}/aix');
    final inputs = unpacked.listSync(recursive: true).whereType<File>().where(
          (f) =>
              f.path.contains('/aars/') ||
              f.path.endsWith('component_build_infos.json'),
        );
    final sizes = [
      for (final file in inputs)
        '${file.path.substring(unpacked.path.length)}:${file.lengthSync()}',
    ]..sort();
    return jsonEncode({
      'inputs': sizes,
      'buildInfos': inputs
          .where((f) => f.path.endsWith('.json'))
          .map((f) => f.readAsStringSync())
          .join(),
      'events': Metadata.fromAix(aix).eventSignature(),
      'companion':
          '${Toolchain.companionAix.lengthSync()}:${Toolchain.companionAix.lastModifiedSync()}',
      'generator': Toolchain.projectGenerator.readAsStringSync(),
    });
  }

  bool matchesDevApp(Directory work) {
    final key = File('${work.path}/dev-app.key');
    return key.existsSync() && key.readAsStringSync() == devAppKey();
  }

  void rememberDevApp(Directory work) =>
      File('${work.path}/dev-app.key').writeAsStringSync(devAppKey());
}

class DevApp {
  DevApp(this.work);

  final Directory work;

  Future<File> build(Staged staged) async {
    final dir = Directory('${work.path}/dev-app');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    final project = Directory('${dir.path}/project')
      ..createSync(recursive: true);
    final out = Directory('${dir.path}/out')..createSync();
    final lib64 = Directory('${dir.path}/tmp/lib64')
      ..createSync(recursive: true);
    final appInventor = (await check('bash', [
      Toolchain.buildServerScript.path,
    ]))
        .trim()
        .split('\n')
        .last;
    await check('python3', [
      '-I',
      Toolchain.projectGenerator.path,
      project.path,
      Toolchain.companionAix.path,
      staged.aix.path,
    ]);
    (await signingKey()).copySync('${project.path}/android.keystore');
    final aia = '${dir.path}/project.aia';
    await check('zip', ['-q', '-r', '-D', aia, '.'], cwd: project.path);
    File('$appInventor/lib/android/tools/linux/lib64/libc++.so')
        .copySync('${lib64.path}/libc++.so');
    final log = File('${dir.path}/build.log');
    final server = await Process.run('${Toolchain.java11}/bin/java', [
      '-Djava.io.tmpdir=${dir.path}/tmp',
      '-Dfile.encoding=UTF-8',
      '-Djava.awt.headless=true',
      '-cp',
      '$appInventor/buildserver/build/run/lib/*',
      'com.google.appinventor.buildserver.Main',
      '--inputZipFile',
      aia,
      '--userName',
      'live',
      '--outputDir',
      out.path,
      '--dexCacheDir',
      '${Toolchain.e2eCache}/dex-cache',
    ]);
    log.writeAsStringSync('${server.stdout}${server.stderr}');
    final apks = out.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.apk'),
        );
    if (server.exitCode != 0 || apks.isEmpty) {
      throw LiveFailure(
        'DevAppBuildFailed',
        'App Inventor could not build the dev app, see ${log.path}',
      );
    }
    return apks.first;
  }

  Future<File> signingKey() async {
    if (!Toolchain.keystore.existsSync()) {
      await check('${Toolchain.java11}/bin/keytool', [
        '-genkey',
        '-keystore',
        Toolchain.keystore.path,
        '-alias',
        'AndroidKey',
        '-keyalg',
        'RSA',
        '-dname',
        'CN=Rush Live, O=AppInventor for Android, C=US',
        '-validity',
        '10000',
        '-storepass',
        'android',
        '-keypass',
        'android',
      ]);
    }
    return Toolchain.keystore;
  }
}

class Panel {
  Panel(this.live, this.feed);

  final Live live;
  final EventFeed feed;
  Map<String, Object?>? lastReload;
  Map<String, Object?>? lastCrash;
  Future<Map<String, Object?>>? reloading;

  static File get tokenFile =>
      File('${Project.find(Directory.current).work.path}/panel.token');
  final token = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static Future<bool> running() async => await forward('ping') != null;

  static Future<Map<String, Object?>?> forward(String action) async {
    if (!tokenFile.existsSync()) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    try {
      final request = await client.post('127.0.0.1', panelPort, '/api/$action');
      request.headers.set('X-Live-Token', tokenFile.readAsStringSync());
      final response = await request.close();
      return jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, Object?>;
    } on SocketException {
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<String, Object?>> reload({bool rebuildApp = false}) {
    return reloading ??=
        lifecycle(() => live.reload(rebuildApp: rebuildApp)).then((report) {
      lastReload = {...report, 'at': DateTime.now().millisecondsSinceEpoch};
      lastCrash = null;
      reloading = null;
      return report;
    });
  }

  Future<Map<String, Object?>> guarded(
    Future<Map<String, Object?>> Function() action,
  ) async {
    try {
      return await action();
    } on LiveFailure catch (failure) {
      return failure.toJson();
    }
  }

  Future<Map<String, Object?>> lifecycle(
    Future<Map<String, Object?>> Function() action,
  ) async {
    final report = await guarded(action);
    if (report['ok'] != true) {
      live.enter('failed');
    }
    return report;
  }

  Future<HttpServer> serve() async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      panelPort,
    );
    (tokenFile..createSync(recursive: true)).writeAsStringSync(token);
    server.listen((request) async {
      final response = request.response;
      try {
        if (!const ['127.0.0.1:$panelPort', 'localhost:$panelPort'].contains(
          request.headers.host == null
              ? null
              : '${request.headers.host}:${request.headers.port}',
        )) {
          response.statusCode = HttpStatus.forbidden;
        } else if (request.uri.path == '/') {
          response.headers.contentType = ContentType.html;
          response.write(
            Toolchain.panelPage.readAsStringSync().replaceFirst(
                  '{{token}}',
                  token,
                ),
          );
        } else if (request.headers.value('X-Live-Token') != token) {
          response.statusCode = HttpStatus.forbidden;
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode(
              LiveFailure('Forbidden', 'Missing or wrong panel token').toJson(),
            ),
          );
        } else {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(await api(request)));
        }
      } on LiveFailure catch (failure) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(failure.toJson()));
      }
      await response.close();
    });
    return server;
  }

  Future<Map<String, Object?>> api(HttpRequest request) async {
    final body =
        request.method == 'POST' ? await utf8.decoder.bind(request).join() : '';
    final input = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    switch (request.uri.path) {
      case '/api/ping':
        return {'ok': true};
      case '/api/state':
        return {
          'ok': true,
          'phase': live.currentPhase,
          'device': live.device.serial,
          'reload': lastReload,
          'crash': lastCrash,
          'session': live.project.session.steps,
          'components': live.project.metadata.components,
        };
      case '/api/builtins':
        return {'ok': true, 'components': live.project.metadata.builtIns};
      case '/api/events':
        return {
          'ok': true,
          ...feed.since(
            int.tryParse(request.uri.queryParameters['since'] ?? '') ?? 0,
          ),
        };
      case '/api/command':
        return guarded(
          () => live.perform(
            input['verb'] as String,
            input['args'] as List<Object?>,
          ),
        );
      case '/api/reload':
        return reload();
      case '/api/rebuild':
        return reload(rebuildApp: true);
      case '/api/restart':
        lastCrash = null;
        return lifecycle(live.restart);
      case '/api/session/clear':
        live.project.session.clear();
        return lifecycle(live.restart);
      case '/api/session/remove':
        live.project.session.removeAt(input['index'] as int);
        return lifecycle(live.restart);
      case '/api/remove':
        return lifecycle(() => live.remove(input['name'] as String));
      default:
        throw LiveFailure.usage('No API ${request.uri.path}');
    }
  }
}

class EventFeed {
  EventFeed(this.live);

  final Live live;
  final List<Map<String, Object?>> events = [];
  final added = StreamController<List<Map<String, Object?>>>.broadcast();
  final crashes = StreamController<Map<String, Object?>?>.broadcast();
  int cursor = 0;

  void start() {
    Timer.periodic(const Duration(milliseconds: 600), (_) => poll());
  }

  bool polling = false;

  Future<void> poll() async {
    if (polling ||
        !const ['ready', 'crashed', 'stopped'].contains(live.currentPhase)) {
      return;
    }
    polling = true;
    try {
      final batch = await live.events(cursor);
      if (live.currentPhase != 'ready') {
        live.enter('ready');
        crashes.add(null);
      }
      cursor = batch['last'] as int;
      final fresh = (batch['events'] as List).cast<Map<String, Object?>>();
      if (fresh.isNotEmpty) {
        events.addAll(fresh);
        if (events.length > 2000) {
          events.removeRange(0, events.length - 2000);
        }
        added.add(fresh);
      }
    } on LiveFailure catch (failure) {
      if (failure.details['crash'] != null && live.currentPhase != 'crashed') {
        live.enter('crashed');
        crashes.add(failure.toJson());
      } else if (failure.type == 'AppNotRunning' &&
          live.currentPhase == 'ready') {
        live.enter('stopped');
      }
    } finally {
      polling = false;
    }
  }

  Map<String, Object?> since(int seq) => {
        'last': events.isEmpty ? seq : events.last['seq'],
        'events': [
          for (final event in events)
            if ((event['seq'] as int) > seq) event,
        ],
      };
}

class Up {
  Up(this.live);

  final Live live;
  final terminal = Terminal(
    stdout.hasTerminal && (Platform.environment['NO_COLOR'] ?? '').isEmpty,
  );
  late final feed = EventFeed(live);
  late final panel = Panel(live, feed);
  bool changedWhileReloading = false;

  Future<void> run() async {
    terminal.check(
      'Device',
      '${await live.device.model()} · ${live.device.serial}',
    );
    await panel.serve();
    terminal.check('Panel', 'http://127.0.0.1:$panelPort');
    feed.start();
    feed.added.stream.listen(terminal.events);
    feed.crashes.stream.listen((crash) {
      panel.lastCrash = crash;
      if (crash == null) {
        terminal.line(
          '${terminal.time()}  ${terminal.paint('32', '●')} The app is running again',
        );
      } else {
        terminal.crash(crash);
      }
    });
    live.phase.stream.listen(terminal.phase);
    await reload();
    terminal.line(
      terminal.dim(
        'Watching ${live.project.root.path} · r reload · b rebuild app · c clear session · q quit',
      ),
    );
    watch();
    await keys();
  }

  Future<void> reload({bool rebuildApp = false}) async {
    if (panel.reloading != null) {
      changedWhileReloading = true;
      return;
    }
    terminal.report(await panel.reload(rebuildApp: rebuildApp));
    if (changedWhileReloading) {
      changedWhileReloading = false;
      await reload();
    }
  }

  static const ignored = {
    '.rush',
    'out',
    '.git',
    '.idea',
    '.gradle',
    'build',
    '.dart_tool',
  };

  void watch() {
    Timer? debounce;
    void changed(FileSystemEvent event) {
      if (event.path.endsWith('live.jsonl') || event.path.endsWith('~')) {
        return;
      }
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), reload);
    }

    void watchDirectory(Directory dir) {
      dir.watch().listen((event) {
        if (event is FileSystemCreateEvent &&
            event.isDirectory &&
            watched(event.path)) {
          watchDirectory(Directory(event.path));
        }
        changed(event);
      });
    }

    for (final dir in [
      live.project.root,
      ...live.project.root.listSync(recursive: true).whereType<Directory>(),
    ]) {
      if (watched(dir.path)) {
        watchDirectory(dir);
      }
    }
  }

  bool watched(String path) => !path
      .substring(live.project.root.path.length)
      .split(Platform.pathSeparator)
      .any(ignored.contains);

  Future<void> keys() async {
    try {
      stdin
        ..echoMode = false
        ..lineMode = false;
    } on StdinException {
      return Completer<void>().future;
    }
    await for (final key in stdin.map(utf8.decode)) {
      switch (key) {
        case 'r':
          await reload();
        case 'b':
          await reload(rebuildApp: true);
        case 'c':
          live.project.session.clear();
          terminal.report(await panel.lifecycle(live.restart));
        case 'q':
          stdin
            ..lineMode = true
            ..echoMode = true;
          exit(0);
      }
    }
  }
}

class Terminal {
  Terminal(this.color);

  final bool color;
  String lastEventKey = '';
  int repeats = 0;

  String paint(String code, String text) =>
      color ? '\x1b[${code}m$text\x1b[0m' : text;
  String dim(String text) => paint('2', text);
  String time() => dim(DateTime.now().toIso8601String().substring(11, 19));

  void line(String text) => stdout.writeln(text);

  void check(String label, String value) =>
      line('${paint('32', '✓')} ${label.padRight(8)} $value');

  void phase(String phase) {
    if (const [
      'building',
      'building dev app',
      'waiting for unlock',
    ].contains(phase)) {
      line('${time()}  ${dim('$phase…')}');
    } else if (phase == 'stopped') {
      line(
        '${time()}  ${dim('the app was closed on the phone: run live restart')}',
      );
    }
  }

  void report(Map<String, Object?> report) {
    if (report['ok'] != true) {
      final error = report['error'] as Map<String, Object?>;
      line('${time()}  ${paint('31', '✗')} ${error['message']}');
      for (final message
          in (error['errors'] as List?) ?? [error['output'] ?? '']) {
        line(
          paint(
            '31',
            '          ${'$message'.replaceAll('\n', '\n          ')}',
          ),
        );
      }
      return;
    }
    final ms = (report['ms'] as Map?)?.values.fold<int>(
          0,
          (sum, value) => sum + (value as int),
        );
    line(
      '${time()}  ${paint('32', '●')} ${ms == null ? 'Restarted' : 'Reloaded in ${(ms / 1000).toStringAsFixed(1)}s'}'
      '${dim(' · replayed ${report['replayed']} steps')}',
    );
    for (final failure in (report['replayFailures'] as List?) ?? const []) {
      final step = failure['step'] as Map;
      line(
        paint(
          '31',
          '          ✗ replay ${(step['args'] as List).join(' ')}: ${failure['error']['type']}: ${failure['error']['message']}',
        ),
      );
    }
    for (final step in (report['removedFromSession'] as List?) ?? const []) {
      line(
        paint(
          '33',
          '          Removed ${(step['args'] as List).join(' ')} from the session: the app crashed right after it',
        ),
      );
    }
    final crash = report['previousCrash'];
    if (crash is Map) {
      line(
        paint(
          '31',
          '          The app crashed before this restart: ${crash['type']}: ${crash['message']}',
        ),
      );
      for (final frame in crash['at'] as List) {
        line(dim('            at $frame'));
      }
    }
  }

  void crash(Map<String, Object?> failure) {
    final error = failure['error'] as Map<String, Object?>;
    final crash = error['crash'];
    line(
      '${time()}  ${paint('31', '✗ The app crashed')}${crash is Map ? ': ${crash['type']}: ${crash['message']}' : ''}',
    );
    for (final frame in crash is Map ? crash['at'] as List : const []) {
      line(dim('            at $frame'));
    }
    final removed = error['removedFromSession'];
    if (removed is Map) {
      line(
        paint(
          '33',
          '          Removed ${(removed['args'] as List).join(' ')} from the session: the app crashed right after it',
        ),
      );
    }
    line(dim('          Press r to reload or save a file'));
  }

  void events(List<Map<String, Object?>> events) {
    for (final event in events) {
      final key = '${event['component']}.${event['event']}';
      if (key == lastEventKey) {
        repeats++;
        continue;
      }
      if (repeats > 0) {
        line(dim('          ↻ $lastEventKey ×${repeats + 1}'));
      }
      lastEventKey = key;
      repeats = 0;
      final named = event['named'] as Map?;
      final args = named == null
          ? (event['args'] as List).map(jsonEncode).join(', ')
          : named.entries
              .map((e) => '${e.key} = ${jsonEncode(e.value)}')
              .join(', ');
      line('${time()}  ${paint('33', 'when')} ${key.padRight(32)} $args');
    }
  }
}
