import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';

abstract interface class LiveActivityPort {
  LiveActivitySnapshot read();
}
