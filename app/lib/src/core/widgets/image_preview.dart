import 'dart:io';

import 'package:flutter/material.dart';

/// Full-screen image preview with pinch-zoom (InteractiveViewer).
void showImagePreview(BuildContext context, String path, {String? title}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.85),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              maxScale: 5.0,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image,
                      size: 64,
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (title != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                title,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    ),
  );
}
