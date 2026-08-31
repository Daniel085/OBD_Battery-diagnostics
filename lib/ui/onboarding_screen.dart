import 'package:flutter/material.dart';

/// First-run onboarding: three swipe pages — what the app does, adapter
/// guidance, and the read-only promise. Shown once (OnboardingStore marker);
/// completing or skipping calls [onDone].
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _Page {
  final IconData icon;
  final String title;
  final String body;
  const _Page(this.icon, this.title, this.body);
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _Page(
      Icons.battery_charging_full,
      'See your EV battery\'s real data',
      'Pack current, temperatures, and module voltages — read directly from '
          'your car\'s control units over a Bluetooth OBD adapter, not '
          'estimated.\n\nMeasure usable capacity and state of health with a '
          'guided charge-session test.',
    ),
    _Page(
      Icons.bluetooth,
      'The adapter matters',
      'A quality BLE adapter is strongly recommended — OBDLink CX or MX+.\n\n'
          'Cheap ELM327 clones often cannot reach the battery bus on modern '
          'EVs (29-bit CAN), and many have Bluetooth quirks. The app works '
          'around the common ones, but a good adapter avoids the pain.\n\n'
          'No adapter yet? Demo mode simulates a Cadillac Lyriq mid-charge.',
    ),
    _Page(
      Icons.lock_outline,
      'Read-only, by design',
      'This app only ever sends diagnostic read requests. It contains no '
          'code that can write to, configure, or clear anything in your '
          'vehicle.\n\nValues are shown as read from (or measured on) your '
          'car — interpreting them is up to you.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: widget.onDone,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(p.icon,
                            size: 64,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 24),
                        Text(p.title,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 16),
                        Text(p.body,
                            style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: last
                        ? widget.onDone
                        : () => _controller.nextPage(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOut,
                            ),
                    child: Text(last ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
