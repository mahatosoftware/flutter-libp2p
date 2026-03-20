import 'dart:async';

class Retry {
  static Future<T> withRetry<T>(
    Future<T> Function() task, {
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 1),
    bool Function(Object)? retryIf,
  }) async {
    int attempts = 0;
    while (true) {
      attempts++;
      try {
        return await task().timeout(const Duration(seconds: 10));
      } catch (e) {
        if (attempts >= maxAttempts || (retryIf != null && !retryIf(e))) {
          rethrow;
        }
        await Future.delayed(delay * attempts);
      }
    }
  }
}
