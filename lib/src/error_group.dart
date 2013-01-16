// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library error_group;

import 'dart:async';

/// An [ErrorGroup] entangles the errors of multiple [Future]s and [Stream]s
/// with one another. This allows APIs to expose multiple [Future]s and
/// [Stream]s that have identical error conditions without forcing API consumers
/// to attach error handling to objects they don't care about.
///
/// To use an [ErrorGroup], register [Future]s and [Stream]s with it using
/// [registerFuture] and [registerStream]. These methods return wrapped versions
/// of the [Future]s and [Stream]s, which should then be used in place of the
/// originals. For example:
///
///     var errorGroup = new ErrorGroup();
///     future = errorGroup.registerFuture(future);
///     stream = errorGroup.registerStream(stream);
///
/// An [ErrorGroup] has two major effects on its wrapped members:
///
/// * An error in any member of the group will be propagated to every member
///   that hasn't already completed. If those members later complete, their
///   values will be ignored.
/// * If any member of this group has a listener, errors on members without
///   listeners won't get passed to the top-level error handler.
class ErrorGroup {
  /// The [Future]s that are members of [this].
  final _futures = <_ErrorGroupFuture>[];

  /// The [Stream]s that are members of [this].
  final _streams = <_ErrorGroupStream>[];

  /// Whether [this] has completed, either successfully or with an error.
  var _isDone = false;

  /// The [Completer] for [done].
  final _doneCompleter = new Completer();

  /// The underlying [Future] for [done]. We need to be able to access it
  /// internally as an [_ErrorGroupFuture] so we can check if it has listeners
  /// and signal errors on it.
  _ErrorGroupFuture _done;

  /// Returns a [Future] that completes successully when all members of [this]
  /// are complete, or with an error if any member receives an error.
  ///
  /// This [Future] is effectively in the group in that an error on it won't be
  /// passed to the top-level error handler unless no members of the group have
  /// listeners attached.
  Future get done => _done;

  /// Creates a new group with no members.
  ErrorGroup() {
    this._done = new _ErrorGroupFuture(this, _doneCompleter.future);
  }

  /// Registers a [Future] as a member of [this]. Returns a wrapped version of
  /// [future] that should be used in its place.
  ///
  /// If all members of [this] have already completed successfully or with an
  /// error, it's a [StateError] to try to register a new [Future].
  Future registerFuture(Future future) {
    if (_isDone) {
      throw new StateError("Can't register new members on a complete "
          "ErrorGroup.");
    }

    var wrapped = new _ErrorGroupFuture(this, future);
    _futures.add(wrapped);
    return wrapped;
  }

  /// Registers a [Stream] as a member of [this]. Returns a wrapped version of
  /// [stream] that should be used in its place. The returned [Stream] will be
  /// multi-subscription if and only if [stream] is.
  ///
  /// Since all errors in a group are passed to all members, the returned
  /// [Stream] will automatically unsubscribe all its listeners when it
  /// encounters an error.
  ///
  /// If all members of [this] have already completed successfully or with an
  /// error, it's a [StateError] to try to register a new [Stream].
  Stream registerStream(Stream stream) {
    if (_isDone) {
      throw new StateError("Can't register new members on a complete "
          "ErrorGroup.");
    }

    var wrapped = new _ErrorGroupStream(this, stream);
    _streams.add(wrapped);
    return wrapped;
  }

  /// Sends [error] to all members of [this]. Like errors that come from
  /// members, this will only be passed to the top-level error handler if no
  /// members have listeners.
  ///
  /// If all members of [this] have already completed successfully or with an
  /// error, it's a [StateError] to try to signal an error.
  void signalError(AsyncError error) {
    if (_isDone) {
      throw new StateError("Can't signal errors on a complete ErrorGroup.");
    }

    _signalError(error);
  }

  /// Signal an error internally. This is just like [signalError], but instead
  /// of throwing an error if [this] is complete, it just does nothing.
  void _signalError(AsyncError error) {
    if (_isDone) return;

    var caught = false;
    for (var future in _futures) {
      if (future._isDone || future._hasListeners) caught = true;
      future._signalError(error);
    }

    for (var stream in _streams) {
      if (stream._isDone || stream._hasListeners) caught = true;
      stream._signalError(error);
    }

    _isDone = true;
    _done._signalError(error);
    if (!caught && !_done._hasListeners) error.throwDelayed();
  }

  /// Notifies [this] that one of its member [Future]s is complete.
  void _signalFutureComplete(_ErrorGroupFuture future) {
    if (_isDone) return;

    _isDone = _futures.every((future) => future._isDone) &&
        _streams.every((stream) => stream._isDone);
    if (_isDone) _doneCompleter.complete();
  }

  /// Notifies [this] that one of its member [Stream]s is complete.
  void _signalStreamComplete(_ErrorGroupStream stream) {
    if (_isDone) return;

    _isDone = _futures.every((future) => future._isDone) &&
        _streams.every((stream) => stream._isDone);
    if (_isDone) _doneCompleter.complete();
  }
}

/// A [Future] wrapper that keeps track of whether it's been completed and
/// whether it has any listeners. It also notifies its parent [ErrorGroup] when
/// it completes successfully or receives an error.
class _ErrorGroupFuture implements Future {
  /// The parent [ErrorGroup].
  final ErrorGroup _group;

  /// Whether [this] has completed, either successfully or with an error.
  var _isDone = false;

  /// The underlying [Completer] for [this].
  final _completer = new Completer();

  /// Whether [this] has any listeners.
  bool _hasListeners = false;

  /// Creates a new [_ErrorGroupFuture] that's a child of [_group] and wraps
  /// [inner].
  _ErrorGroupFuture(this._group, Future inner) {
    inner.then((value) {
      if (!_isDone) _completer.complete(value);
      _isDone = true;
      _group._signalFutureComplete(this);
    }).catchError((error) => _group._signalError(error));

    // Make sure _completer.future doesn't automatically send errors to the
    // top-level.
    _completer.future.catchError((_) {});
  }

  Future then(onValue(T value), {onError(AsyncError asyncError)}) {
    _hasListeners = true;
    return _completer.future.then(onValue, onError: onError);
  }

  Future catchError(onError(AsyncError asyncError), {bool test(Object error)}) {
    _hasListeners = true;
    return _completer.future.catchError(onError, test: test);
  }

  Future whenComplete(void action()) {
    _hasListeners = true;
    return _completer.future.whenComplete(action);
  }

  Stream<T> asStream() {
    _hasListeners = true;
    return _completer.future.asStream();
  }

  /// Signal that an error from [_group] should be propagated through [this],
  /// unless it's already complete.
  void _signalError(AsyncError error) {
    if (!_isDone) _completer.completeError(error.error, error.stackTrace);
    _isDone = true;
  }
}

// TODO(nweiz): currently streams never top-level unhandled errors (issue 7843).
// When this is fixed, this class will need to prevent such errors from being
// top-leveled.
/// A [Stream] wrapper that keeps track of whether it's been completed and
/// whether it has any listeners. It also notifies its parent [ErrorGroup] when
/// it completes successfully or receives an error.
class _ErrorGroupStream extends Stream {
  /// The parent [ErrorGroup].
  final ErrorGroup _group;

  /// Whether [this] has completed, either successfully or with an error.
  var _isDone = false;

  /// The underlying [StreamController] for [this].
  final StreamController _controller;

  /// The [StreamSubscription] that connects the wrapped [Stream] to
  /// [_controller].
  StreamSubscription _subscription;

  /// Whether [this] has any listeners.
  bool get _hasListeners => _controller.hasSubscribers;

  /// Creates a new [_ErrorGroupFuture] that's a child of [_group] and wraps
  /// [inner].
  _ErrorGroupStream(this._group, Stream inner)
    : _controller = inner.isSingleSubscription ?
          new StreamController() :
          new StreamController.multiSubscription() {
    _subscription = inner.listen(_controller.add,
        onError: (e) => _group._signalError(e),
        onDone: () {
          _isDone = true;
          _group._signalStreamComplete(this);
          _controller.close();
        });
  }

  StreamSubscription listen(void onData(value),
      {void onError(AsyncError error), void onDone(),
       bool unsubscribeOnError}) {
    return _controller.listen(onData,
        onError: onError,
        onDone: onDone,
        unsubscribeOnError: true);
  }

  /// Signal that an error from [_group] should be propagated through [this],
  /// unless it's already complete.
  void _signalError(AsyncError e) {
    if (_isDone) return;
    _subscription.cancel();
    // Call these asynchronously to work around issue 7913.
    new Future.immediate(null).then((_) {
      _controller.signalError(e.error, e.stackTrace);
      _controller.close();
    });
  }
}