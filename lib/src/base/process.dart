import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:process/process.dart';

import 'context.dart';
import 'logger.dart';

/// Execute command [cmd] with arguments [arguments] in a separate process
/// and return stdout as string.
///
/// If [silent] is false, output to stdout.
String cmd(List<String> cmd,
    {String workingDirectory = '.', bool silent = true}) {
//  print(
//      'cmd=\'${cmd.join(" ")}\', workingDir=$workingDir, silent=$silent');
  final result = processManager.runSync(cmd,
      workingDirectory: workingDirectory, runInShell: true);
  _traceCommand(cmd, workingDirectory: workingDirectory);
  if (!silent) stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw 'command failed: exitcode=${result.exitCode}, cmd=\'${cmd.join(" ")}\', workingDir=$workingDirectory';
  }
  // return stdout
  return result.stdout;
}

/// Execute command [cmd] with arguments [arguments] in a separate process
/// and stream stdout/stderr.
Future<void> streamCmd(List<String> cmd,
    {String workingDirectory = '.'}) async {
//  print(
//      'streamCmd=\'$cmd ${arguments.join(" ")}\', workingDirectory=$workingDirectory, mode=$mode');
  final exitCode =
      await runCommandAndStreamOutput(cmd, workingDirectory: workingDirectory);
  if (exitCode != 0) {
    throw 'command failed: exitcode=$exitCode, cmd=\'${cmd.join(" ")}\', workingDirectory=$workingDirectory';
  }
}

const ProcessManager _kLocalProcessManager = LocalProcessManager();

typedef StringConverter = String Function(String string);

/// The active process manager.
ProcessManager get processManager =>
    context.get<ProcessManager>() ?? _kLocalProcessManager;

/// This runs the command in the background from the specified working
/// directory. Completes when the process has been started.
Future<Process> runCommand(
  List<String> cmd, {
  String workingDirectory,
  Map<String, String> environment,
}) {
  _traceCommand(cmd, workingDirectory: workingDirectory);
  return processManager.start(
    cmd,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

/// This runs the command and streams stdout/stderr from the child process to
/// this process' stdout/stderr. Completes with the process's exit code.
///
/// If [filter] is null, no lines are removed.
///
/// If [filter] is non-null, all lines that do not match it are removed. If
/// [mapFunction] is present, all lines that match [filter] are also forwarded
/// to [mapFunction] for further processing.
Future<int> runCommandAndStreamOutput(
  List<String> cmd, {
  String workingDirectory,
  String prefix = '',
  bool trace = false,
  RegExp filter,
  StringConverter mapFunction,
  Map<String, String> environment,
}) async {
  final Process process = await runCommand(
    cmd,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final StreamSubscription<String> stdoutSubscription = process.stdout
      .transform<String>(utf8.decoder)
      .transform<String>(const LineSplitter())
      .where((String line) => filter == null ? true : filter.hasMatch(line))
      .listen((String line) {
    if (mapFunction != null) line = mapFunction(line);
    if (line != null) {
      final String message = '$prefix$line';
      if (trace)
        printTrace(message);
      else
        printStatus(message, wrap: false);
    }
  });
  final StreamSubscription<String> stderrSubscription = process.stderr
      .transform<String>(utf8.decoder)
      .transform<String>(const LineSplitter())
      .where((String line) => filter == null ? true : filter.hasMatch(line))
      .listen((String line) {
    if (mapFunction != null) line = mapFunction(line);
    if (line != null) printError('$prefix$line', wrap: false);
  });

  // Wait for stdout to be fully processed
  // because process.exitCode may complete first causing flaky tests.
  await waitGroup<void>(<Future<void>>[
    stdoutSubscription.asFuture<void>(),
    stderrSubscription.asFuture<void>(),
  ]);

  await waitGroup<void>(<Future<void>>[
    stdoutSubscription.cancel(),
    stderrSubscription.cancel(),
  ]);

  return await process.exitCode;
}

/// Returns a [Future] that completes when all given [Future]s complete.
///
/// Uses [Future.wait] but removes null elements from the provided
/// `futures` iterable first.
///
/// The returned [Future<List>] will be shorter than the given `futures` if
/// it contains nulls.
Future<List<T>> waitGroup<T>(Iterable<Future<T>> futures) {
  return Future.wait<T>(futures.where((Future<T> future) => future != null));
}

const FileSystem _kLocalFs = LocalFileSystem();

/// Currently active implementation of the file system.
///
/// By default it uses local disk-based implementation. Override this in tests
/// with [MemoryFileSystem].
FileSystem get fs => _kLocalFs;

void _traceCommand(List<String> args, {String workingDirectory}) {
  final String argsText = args.join(' ');
  if (workingDirectory == null) {
    printTrace('executing: $argsText');
  } else {
    printTrace('executing: [$workingDirectory${fs.path.separator}] $argsText');
  }
}
