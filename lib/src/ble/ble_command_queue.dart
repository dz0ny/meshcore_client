import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../meshcore_constants.dart';

/// Type of response expected from a command
enum CommandResponseType {
  /// No response expected (fire-and-forget)
  none,

  /// Wait for RESP_CODE_OK (0) or RESP_CODE_ERR (1)
  ack,

  /// Wait for specific response code with data
  data,
}

/// Represents a queued BLE command
class QueuedCommand<T> {
  /// The command data to send
  final Uint8List data;

  /// Command code (first byte of data)
  final int commandCode;

  /// Type of response expected
  final CommandResponseType responseType;

  /// Expected response code (for data type commands)
  final int? expectedResponseCode;

  /// Completer to signal command completion
  final Completer<T> completer;

  /// Timeout duration for this command
  final Duration timeout;

  /// Timestamp when command was enqueued
  final DateTime enqueuedAt;

  /// Response key used in [_pendingResponses], set when command is scheduled.
  int? responseKey;

  /// Completes when the command becomes the active command allowed to send.
  final Completer<void> activated;

  QueuedCommand({
    required this.data,
    required this.commandCode,
    required this.responseType,
    this.expectedResponseCode,
    required this.completer,
    required this.timeout,
  }) : enqueuedAt = DateTime.now(),
       activated = Completer<void>();
}

class EnqueuedCommandHandle<T> {
  final Future<T> completion;
  final Future<void> active;

  EnqueuedCommandHandle({
    required this.completion,
    required this.active,
  });
}

/// BLE command queue with serialized command execution
///
/// Ensures that:
/// - Only one command executes at a time
/// - Commands can wait for ACK or specific responses
/// - Timeouts are enforced
class BleCommandQueue {
  // Queue of pending commands
  final List<QueuedCommand> _queue = [];

  // Mutex lock using Completer
  Completer<void> _lock = Completer<void>()..complete();

  // Whether queue is currently processing
  bool _isProcessing = false;

  // Pending responses bucketed by response code key.
  final Map<int, ListQueue<QueuedCommand>> _pendingResponses = {};

  // Callbacks
  VoidCallback? onQueueEmpty;
  void Function(int queueSize)? onQueueSizeChanged;

  /// Enqueue a command and wait for it to complete
  ///
  /// [data] - The command data to send
  /// [commandCode] - Command code (first byte)
  /// [responseType] - Type of response expected
  /// [expectedResponseCode] - For data responses, the expected response code
  /// [timeout] - Maximum time to wait for response
  ///
  /// Returns a Future that completes when the command receives its response
  /// or throws TimeoutException if timeout expires.
  EnqueuedCommandHandle<T> enqueueCommand<T>({
    required Uint8List data,
    required int commandCode,
    required CommandResponseType responseType,
    int? expectedResponseCode,
    Duration? timeout,
  }) {
    // Determine timeout based on response type
    final cmdTimeout =
        timeout ??
        (responseType == CommandResponseType.data
            ? const Duration(seconds: 10)
            : const Duration(seconds: 5));

    // Create queued command
    final command = QueuedCommand<T>(
      data: data,
      commandCode: commandCode,
      responseType: responseType,
      expectedResponseCode: expectedResponseCode,
      completer: Completer<T>(),
      timeout: cmdTimeout,
    );

    // Add to queue
    _queue.add(command);
    onQueueSizeChanged?.call(_queue.length);

    if (command.responseType != CommandResponseType.none) {
      final responseKey = _responseKeyFor(command);
      command.responseKey = responseKey;
      _pendingResponses.putIfAbsent(responseKey, ListQueue.new).addLast(command);
    }

    debugPrint(
      '📋 [CommandQueue] Enqueued command 0x${commandCode.toRadixString(16).padLeft(2, '0')} (queue size: ${_queue.length})',
    );

    // Start processing if not already running
    if (!_isProcessing) {
      _processQueue();
    }

    // Wait for command to complete or timeout
    final completion = command.completer.future.timeout(
      cmdTimeout,
      onTimeout: () {
        debugPrint(
          '⏱️ [CommandQueue] Command 0x${commandCode.toRadixString(16).padLeft(2, '0')} timed out after ${cmdTimeout.inSeconds}s',
        );
        _removePendingCommand(command);
        if (!command.completer.isCompleted) {
          command.completer.completeError(
            TimeoutException(
              'Command 0x${commandCode.toRadixString(16).padLeft(2, '0')} timed out',
            ),
          );
        }
        throw TimeoutException(
          'Command 0x${commandCode.toRadixString(16).padLeft(2, '0')} timed out',
        );
      },
    );

    return EnqueuedCommandHandle<T>(
      completion: completion,
      active: command.activated.future,
    );
  }

  Future<T> enqueue<T>({
    required Uint8List data,
    required int commandCode,
    required CommandResponseType responseType,
    int? expectedResponseCode,
    Duration? timeout,
  }) {
    return enqueueCommand<T>(
      data: data,
      commandCode: commandCode,
      responseType: responseType,
      expectedResponseCode: expectedResponseCode,
      timeout: timeout,
    ).completion;
  }

  /// Process the command queue
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      // Wait for lock
      await _lock.future;

      // Get next command
      final command = _queue.removeAt(0);
      onQueueSizeChanged?.call(_queue.length);

      try {
        // Create new lock for next command
        _lock = Completer<void>();

        // Execute command (handled by BleCommandSender)
        // The completer will be completed by completeCommand() when response arrives
        debugPrint(
          '📤 [CommandQueue] Executing command 0x${command.commandCode.toRadixString(16).padLeft(2, '0')}',
        );
        if (!command.activated.isCompleted) {
          command.activated.complete();
        }

        // For fire-and-forget commands, complete immediately
        if (command.responseType == CommandResponseType.none) {
          command.completer.complete(null);
          if (!_lock.isCompleted) {
            _lock.complete();
          }
        } else {
          // Keep queue serialized for commands that require a response.
          try {
            await command.completer.future;
          } catch (_) {
            // Errors are propagated to awaiters via the command future.
          } finally {
            if (!_lock.isCompleted) {
              _lock.complete();
            }
          }
        }
      } catch (e) {
        debugPrint('❌ [CommandQueue] Error processing command: $e');
        if (!command.completer.isCompleted) {
          command.completer.completeError(e);
        }
        // Release lock on error
        if (!_lock.isCompleted) {
          _lock.complete();
        }
      }
    }

    _isProcessing = false;
    onQueueEmpty?.call();
    debugPrint('✅ [CommandQueue] Queue empty');
  }

  int _responseKeyFor(QueuedCommand command) {
    // ACK commands are completed by RESP_CODE_OK (0x00). RESP_CODE_ERR
    // is handled via completeCurrentCommandWithError().
    if (command.responseType == CommandResponseType.ack) {
      return MeshCoreConstants.respOk;
    }
    return command.expectedResponseCode ?? command.commandCode;
  }

  /// Complete a pending command with response data
  ///
  /// Called by BleResponseHandler when a response is received
  void completeCommand<T>(int responseCode, T data) {
    final command = _popPendingCommand(responseCode);
    if (command != null) {
      debugPrint(
        '✅ [CommandQueue] Completing command 0x${command.commandCode.toRadixString(16).padLeft(2, '0')} with response 0x${responseCode.toRadixString(16).padLeft(2, '0')}',
      );
      if (!command.completer.isCompleted) {
        command.completer.complete(data);
      }
    }
  }

  /// Complete a pending command with error
  ///
  /// Called by BleResponseHandler when RESP_CODE_ERR is received
  void completeCommandWithError(
    int commandCode,
    String error, {
    int? errorCode,
  }) {
    final command = _popPendingCommand(commandCode);
    if (command != null) {
      debugPrint(
        '❌ [CommandQueue] Command 0x${commandCode.toRadixString(16).padLeft(2, '0')} failed: $error (code: $errorCode)',
      );
      if (!command.completer.isCompleted) {
        command.completer.completeError(
          Exception('Command failed: $error (error code: $errorCode)'),
        );
      }
    }
  }

  /// Complete all currently pending commands with an error
  ///
  /// Used when RESP_CODE_ERR arrives without a way to identify which command
  /// caused it. Since the queue processes one command at a time, at most one
  /// command is pending at any given moment.
  void completeCurrentCommandWithError(String error, {int? errorCode}) {
    for (final entry in _pendingResponses.entries.toList()) {
      while (entry.value.isNotEmpty) {
        final command = entry.value.removeFirst();
        if (!command.completer.isCompleted) {
          debugPrint(
            '❌ [CommandQueue] Command 0x${command.commandCode.toRadixString(16).padLeft(2, '0')} failed: $error (code: $errorCode)',
          );
          command.completer.completeError(
            Exception('Command failed: $error (error code: $errorCode)'),
          );
        }
      }
      if (entry.value.isEmpty) {
        _pendingResponses.remove(entry.key);
      }
    }
  }

  /// Get current queue size
  int get queueSize => _queue.length;

  /// Get number of pending responses
  int get pendingResponseCount =>
      _pendingResponses.values.fold(0, (sum, bucket) => sum + bucket.length);

  /// Check if queue is empty
  bool get isEmpty => _queue.isEmpty;

  /// Check if queue is processing
  bool get isProcessing => _isProcessing;

  /// Clear all pending commands (use with caution)
  void clear() {
    debugPrint(
      '🗑️ [CommandQueue] Clearing queue (${_queue.length} commands, ${_pendingResponses.length} pending responses)',
    );

    // Complete all pending commands with error
    for (final bucket in _pendingResponses.values) {
      for (final command in bucket) {
        if (!command.completer.isCompleted) {
          command.completer.completeError(Exception('Queue cleared'));
        }
      }
    }

    _queue.clear();
    _pendingResponses.clear();
    onQueueSizeChanged?.call(0);
  }

  /// Dispose resources
  void dispose() {
    clear();
    if (!_lock.isCompleted) {
      _lock.complete();
    }
  }

  QueuedCommand? _popPendingCommand(int responseCode) {
    final bucket = _pendingResponses[responseCode];
    if (bucket == null || bucket.isEmpty) return null;
    final command = bucket.removeFirst();
    if (bucket.isEmpty) {
      _pendingResponses.remove(responseCode);
    }
    return command;
  }

  void _removePendingCommand(QueuedCommand command) {
    final responseKey = command.responseKey ?? _responseKeyFor(command);
    final bucket = _pendingResponses[responseKey];
    if (bucket == null) return;
    bucket.remove(command);
    if (bucket.isEmpty) {
      _pendingResponses.remove(responseKey);
    }
  }
}
