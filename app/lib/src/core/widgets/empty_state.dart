import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Empty-state placeholder with a gentle Lottie animation.
class EmptyState extends StatelessWidget {
  const EmptyState({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Lottie.asset('assets/lottie/empty_state.json',
              width: 120, height: 120),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: scheme.outline)),
        ],
      ),
    );
  }
}
