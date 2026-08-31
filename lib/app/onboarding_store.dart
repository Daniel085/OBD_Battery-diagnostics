/// Remembers whether first-run onboarding has been completed, as a marker
/// file in the app documents directory (no extra dependency needed).
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OnboardingStore {
  final Future<File> Function() _resolve;

  OnboardingStore(this._resolve);

  factory OnboardingStore.documents() => OnboardingStore(() async {
        final dir = await getApplicationDocumentsDirectory();
        return File('${dir.path}/onboarding_done');
      });

  factory OnboardingStore.inDirectory(Directory dir) =>
      OnboardingStore(() async => File('${dir.path}/onboarding_done'));

  Future<bool> isDone() async {
    try {
      return await (await _resolve()).exists();
    } on IOException {
      return true; // fail closed: never trap a user in onboarding
    }
  }

  Future<void> markDone() async {
    try {
      await (await _resolve()).writeAsString('1');
    } on IOException {
      // Best-effort; worst case onboarding shows once more.
    }
  }
}
