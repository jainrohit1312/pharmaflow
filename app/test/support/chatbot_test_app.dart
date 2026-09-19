/// The pump helper for the chatbot screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
///
/// The screen is pumped **on its own**, not through a router. Nothing on it
/// navigates, and the real router reads a Supabase session while it builds — but
/// the reason that matters here is a smaller one: GoRouter builds a route more than
/// once before the first frame settles, so a fake that consumed anything on a build
/// would be consumed before the test looked. Pumping the screen directly removes
/// that whole class of surprise.
library;

import 'package:app/features/chatbot/presentation/chatbot_screen.dart';
import 'package:app/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// Pumps the chatbot screen over [service].
///
/// The window is made tall before anything is pumped: the transcript is a
/// `ListView`, which builds only what is on screen, and a bubble below the fold
/// would be missing rather than merely off-screen.
///
/// Pass `settle: false` to look at the screen before its first frame is done — but
/// note the sharper rule for this screen: while a turn is **pending** the spinner
/// animates for ever, so `pumpAndSettle` never returns. A test of the waiting state
/// uses `pump()`.
Future<void> pumpChatbotApp(
  WidgetTester tester, {
  required FakeChatService service,
  Size size = const Size(1000, 1400),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      // The override list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export.
      overrides: [chatServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: ChatbotScreen()),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

/// Types [question] into the composer and taps Ask.
Future<void> askQuestion(WidgetTester tester, String question) async {
  await tester.enterText(find.byType(TextFormField), question);
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Ask'));
}
