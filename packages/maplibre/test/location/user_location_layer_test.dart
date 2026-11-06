import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre/src/location/user_location_layer.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:mocktail/mocktail.dart';

import '../shared/mocks.dart';
import '../shared/ui_app.dart';

const _camera = CameraPosition(
  center: Geographic(lon: 0, lat: 0),
  zoom: 10,
  bearing: 30,
  pitch: 0,
);

const String _source = UserLocationLayer.sourceId;
const String _heading = UserLocationLayer.headingLayerId;
const String _dot = UserLocationLayer.dotLayerId;

/// Records what reaches the map of a style.
class _Backend extends Mock implements StyleBackend {
  final calls = <String>[];
  final layers = <String, Map<String, Object?>>{};

  /// The GeoJSON of each source update, in order.
  final updates = <String>[];

  @override
  Future<void> addSource(Source source) async =>
      calls.add('addSource ${source.id}');

  @override
  Future<void> removeSource(String id) async => calls.add('removeSource $id');

  @override
  Future<void> setGeoJsonData(String id, GeoJsonData data) async {
    calls.add('setGeoJsonData $id');
    updates.add(data.toText());
  }

  @override
  Future<void> addLayer(
    Map<String, Object?> json, {
    String? belowLayerId,
  }) async {
    layers[json['id']! as String] = json;
    calls.add('addLayer ${json['id']} below $belowLayerId');
  }

  @override
  Future<void> removeLayer(String id) async => calls.add('removeLayer $id');
}

/// A style of a map, with real collections over a recording backend.
class _Style {
  _Style({List<Map<String, Object?>> layers = const []}) {
    final sources = StyleSources(backend);
    final styleLayers = StyleLayers(backend, sources: sources)..load(layers);
    when(() => controller.sources).thenReturn(sources);
    when(() => controller.layers).thenReturn(styleLayers);
    when(() => controller.batch(any())).thenAnswer(
      (invocation) =>
          (invocation.positionalArguments.single as void Function())(),
    );
    when(
      () => controller.addImageFromCanvas(
        id: any(named: 'id'),
        painter: any(named: 'painter'),
        width: any(named: 'width'),
        height: any(named: 'height'),
      ),
    ).thenAnswer((invocation) async {
      backend.calls.add('addImage ${invocation.namedArguments[#id]}');
    });
    when(() => controller.removeImage(any())).thenAnswer((invocation) async {
      backend.calls.add('removeImage ${invocation.positionalArguments[0]}');
    });
  }

  final backend = _Backend();
  final controller = MockStyleController();

  List<String> get calls => backend.calls;

  int get updates => backend.updates.length;

  /// The kinds of the features of the last update.
  List<String> get kinds => [
    for (final feature
        in (jsonDecode(backend.updates.last) as Map)['features'] as List)
      ((feature as Map)['properties'] as Map)['k'] as String,
  ];
}

void main() {
  setUpAll(() {
    registerFallbackValue(const CameraUpdate.position());
    registerFallbackValue(const CameraAnimation.ease());
    registerFallbackValue(const Geographic(lon: 0, lat: 0));
    registerFallbackValue(() {});
    registerFallbackValue((Canvas canvas) {});
  });

  group('UserLocationLayer', () {
    late MockMapController controller;
    late StreamController<UserLocation> locations;
    late List<UserLocationTracking> trackingChanges;
    late _Style style;

    setUp(() {
      controller = MockMapController();
      locations = StreamController<UserLocation>.broadcast();
      trackingChanges = [];
      style = _Style(
        layers: [
          {'id': 'background', 'type': 'background'},
          {'id': 'labels', 'type': 'symbol', 'source': 'x'},
        ],
      );
      when(() => controller.style).thenReturn(style.controller);
      when(
        () =>
            controller.animateCamera(any(), animation: any(named: 'animation')),
      ).thenAnswer((_) async => CameraAnimationResult.completed);
    });

    tearDown(() => locations.close());

    Widget app({
      UserLocationTracking tracking = UserLocationTracking.none,
      double? trackingZoom,
      CameraPosition camera = _camera,
      UserLocationStyle locationStyle = const UserLocationStyle(),
      Color color = const Color(0xFF1A73E8),
      String? belowLayerId,
      bool layer = true,
    }) => App(
      camera: camera,
      controller: controller,
      style: controller.style,
      children: [
        if (layer)
          UserLocationLayer(
            locations: locations.stream,
            tracking: tracking,
            trackingZoom: trackingZoom,
            onTrackingChanged: trackingChanges.add,
            style: locationStyle,
            color: color,
            belowLayerId: belowLayerId,
          ),
      ],
    );

    Future<void> pump(
      WidgetTester tester, {
      UserLocationTracking tracking = UserLocationTracking.none,
      double? trackingZoom,
    }) =>
        tester.pumpWidget(app(tracking: tracking, trackingZoom: trackingZoom));

    Future<void> add(WidgetTester tester, UserLocation location) async {
      locations.add(location);
      await tester.pump();
    }

    testWidgets('adds its source and layers below the labels', (tester) async {
      await pump(tester);
      expect(style.calls, [
        'addSource $_source',
        'addLayer ${UserLocationLayer.accuracyLayerId} below labels',
        'addLayer ${UserLocationLayer.dotLayerId} below labels',
        'addImage $_source-heading-1',
        'addLayer ${UserLocationLayer.headingLayerId} below ${UserLocationLayer.dotLayerId}',
      ]);
      expect(style.controller.layers.map((layer) => layer.id), [
        'background',
        UserLocationLayer.accuracyLayerId,
        UserLocationLayer.headingLayerId,
        UserLocationLayer.dotLayerId,
        'labels',
      ]);
    });

    testWidgets('goes below belowLayerId, or on top without labels', (
      tester,
    ) async {
      await tester.pumpWidget(app(belowLayerId: 'background'));
      expect(style.calls[1], endsWith('below background'));
      await tester.pumpWidget(app(layer: false));

      final plain = _Style(
        layers: [
          {'id': 'background', 'type': 'background'},
        ],
      );
      when(() => controller.style).thenReturn(plain.controller);
      // A missing layer falls back to the labels, here none: on top.
      await tester.pumpWidget(app(belowLayerId: 'missing'));
      expect(plain.calls[1], endsWith('below null'));
    });

    testWidgets('draws the dot facing the screen and the cone on the ground', (
      tester,
    ) async {
      await pump(tester);
      final dot = style.backend.layers[UserLocationLayer.dotLayerId]!;
      expect(dot['type'], 'circle');
      expect(dot['paint'], containsPair('circle-pitch-alignment', 'viewport'));
      expect(dot['paint'], containsPair('circle-pitch-scale', 'viewport'));
      expect(dot['paint'], containsPair('circle-radius', 8));
      final heading = style.backend.layers[UserLocationLayer.headingLayerId]!;
      expect(heading['type'], 'symbol');
      expect(
        heading['layout'],
        containsPair('icon-image', '$_source-heading-1'),
      );
      // Turned from north on the ground.
      expect(heading['layout'], containsPair('icon-rotate', ['get', 'h']));
      expect(heading['layout'], containsPair('icon-rotation-alignment', 'map'));
      expect(heading['layout'], containsPair('icon-pitch-alignment', 'map'));
      expect(heading['layout'], containsPair('icon-allow-overlap', true));
      expect(heading['layout'], containsPair('icon-ignore-placement', true));
      expect(
        style.backend.layers[UserLocationLayer.accuracyLayerId]!['type'],
        'fill',
      );
    });

    testWidgets('shows the location by updating its source', (tester) async {
      await pump(tester);
      await add(
        tester,
        const UserLocation(
          position: Geographic(lon: 0.1, lat: 0.05),
          accuracy: 20,
          heading: 10,
        ),
      );
      expect(style.updates, 1);
      expect(style.kinds.first, 'accuracy');
      expect(style.kinds.last, 'dot');
      expect(style.kinds, contains('heading'));
      // Without a heading, the cone goes.
      await tester.pump(UserLocationLayer.updateInterval);
      await add(
        tester,
        const UserLocation(
          position: Geographic(lon: 0.1, lat: 0.05),
          accuracy: 20,
        ),
      );
      expect(style.updates, 2);
      expect(style.kinds, ['accuracy', 'dot']);
    });

    testWidgets('skips locations that look the same', (tester) async {
      await pump(tester);
      const position = Geographic(lon: 1, lat: 2);
      await add(tester, const UserLocation(position: position, heading: 359.6));
      expect(style.updates, 1);
      await tester.pump(UserLocationLayer.updateInterval);
      // The same, and turned by less than 1° across north.
      await add(tester, const UserLocation(position: position, heading: 359.6));
      await add(tester, const UserLocation(position: position, heading: 0.5));
      await tester.pump(UserLocationLayer.updateInterval);
      expect(style.updates, 1);
      // Turned by 1°.
      await add(tester, const UserLocation(position: position, heading: 0.6));
      expect(style.updates, 2);
      await tester.pump(UserLocationLayer.updateInterval);
      // Moved.
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2.000001)),
      );
      expect(style.updates, 3);
    });

    testWidgets('updates at most 30 times a second, ending on the latest', (
      tester,
    ) async {
      await pump(tester);
      // 120 headings a second for a second, each 2° on.
      for (var i = 0; i < 120; i++) {
        locations.add(
          UserLocation(
            position: const Geographic(lon: 1, lat: 2),
            heading: i * 2.0,
          ),
        );
        await tester.pump(const Duration(microseconds: 8334));
      }
      await tester.pump(UserLocationLayer.updateInterval);
      expect(style.updates, inInclusiveRange(29, 31));
      final last = jsonDecode(style.backend.updates.last) as Map;
      final cone = (last['features'] as List).firstWhere(
        (feature) => ((feature as Map)['properties'] as Map)['k'] == 'heading',
      );
      // The last update shows the last heading.
      expect(((cone as Map)['properties'] as Map)['h'], 238);
      // Nothing more without new locations.
      final updates = style.updates;
      await tester.pump(const Duration(seconds: 1));
      expect(style.updates, updates);
    });

    testWidgets('neither updates nor rebuilds when the camera moves', (
      tester,
    ) async {
      // As in a map, whose children stay the same widgets while it rebuilds
      // with each camera.
      final layer = UserLocationLayer(locations: locations.stream);
      Widget map(CameraPosition camera) => App(
        camera: camera,
        controller: controller,
        style: style.controller,
        children: [layer],
      );
      await tester.pumpWidget(map(_camera));
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 5),
      );
      await tester.pump(UserLocationLayer.updateInterval);
      final calls = List.of(style.calls);
      Listener listener() => tester.widget<Listener>(
        find.descendant(
          of: find.byType(UserLocationLayer),
          matching: find.byType(Listener),
        ),
      );
      final built = listener();
      for (var i = 0; i < 20; i++) {
        await tester.pumpWidget(
          map(
            CameraPosition(
              center: Geographic(lon: i * 0.01, lat: 0),
              zoom: 10 + i * 0.1,
              bearing: i * 10.0,
              pitch: i * 3.0,
            ),
          ),
        );
      }
      expect(style.calls, calls);
      // The same widget: the layer did not build again.
      expect(listener(), same(built));
    });

    testWidgets('adds itself to each new style', (tester) async {
      await pump(tester);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 5),
      );
      final next = _Style(
        layers: [
          {'id': 'water', 'type': 'fill', 'source': 'x'},
          {'id': 'names', 'type': 'symbol', 'source': 'x'},
        ],
      );
      when(() => controller.style).thenReturn(next.controller);
      // While the new style loads, the map hands out none.
      when(() => controller.style).thenReturn(null);
      await tester.pumpWidget(app());
      expect(next.calls, isEmpty);
      when(() => controller.style).thenReturn(next.controller);
      await tester.pumpWidget(app());
      await tester.pump();
      expect(next.calls, [
        'addSource $_source',
        'addLayer ${UserLocationLayer.accuracyLayerId} below names',
        'addLayer ${UserLocationLayer.dotLayerId} below names',
        'addImage $_source-heading-2',
        'addLayer $_heading below $_dot',
      ]);
      // With the latest location already in it.
      final source = next.controller.sources[_source]! as GeoJsonSourceData;
      expect(source.data.toText(), contains('"dot"'));
      expect(source.data.toText(), contains('"heading"'));
      // The old style is left alone, and gets nothing new.
      final old = List.of(style.calls);
      await tester.pump(UserLocationLayer.updateInterval);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 3, lat: 4)),
      );
      expect(style.calls, old);
      expect(next.updates, 1);
    });

    testWidgets('takes the next IDs when they are in use', (tester) async {
      await tester.pumpWidget(
        App(
          camera: _camera,
          controller: controller,
          style: style.controller,
          children: [
            UserLocationLayer(locations: locations.stream),
            const UserLocationLayer(locations: Stream.empty()),
          ],
        ),
      );
      expect(style.controller.sources[_source], isNotNull);
      expect(style.controller.sources['$_source-2'], isNotNull);
      expect(style.controller.layers['$_source-2-dot'], isNotNull);
    });

    testWidgets('restyles its layers in place', (tester) async {
      await pump(tester);
      style.calls.clear();
      await tester.pumpWidget(app(color: const Color(0xFFFF0000)));
      await tester.pump();
      expect(style.calls, [
        'removeLayer ${UserLocationLayer.accuracyLayerId}',
        'removeLayer ${UserLocationLayer.headingLayerId}',
        'removeLayer ${UserLocationLayer.dotLayerId}',
        'removeImage $_source-heading-1',
        'addLayer ${UserLocationLayer.accuracyLayerId} below labels',
        'addLayer ${UserLocationLayer.dotLayerId} below labels',
        'addImage $_source-heading-2',
        'addLayer ${UserLocationLayer.headingLayerId} below ${UserLocationLayer.dotLayerId}',
      ]);
      expect(
        style.backend.layers[UserLocationLayer.dotLayerId]!['paint'],
        containsPair('circle-color', '#ff0000'),
      );
      // Without the cone, its layer goes and the source drops it.
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 5),
      );
      await tester.pump(UserLocationLayer.updateInterval);
      expect(style.kinds, contains('heading'));
      style.calls.clear();
      await tester.pumpWidget(
        app(
          color: const Color(0xFFFF0000),
          locationStyle: const UserLocationStyle(showHeading: false),
        ),
      );
      await tester.pump();
      expect(style.controller.layers[UserLocationLayer.headingLayerId], isNull);
      expect(style.calls, contains('removeImage $_source-heading-2'));
      expect(style.kinds, ['dot']);
    });

    testWidgets('removes its source and layers when it goes', (tester) async {
      await pump(tester);
      style.calls.clear();
      await tester.pumpWidget(app(layer: false));
      expect(style.calls, [
        'removeLayer ${UserLocationLayer.accuracyLayerId}',
        'removeLayer ${UserLocationLayer.headingLayerId}',
        'removeLayer ${UserLocationLayer.dotLayerId}',
        'removeSource $_source',
        'removeImage $_source-heading-1',
      ]);
      expect(style.controller.sources[_source], isNull);
    });

    testWidgets('does not move the camera without tracking', (tester) async {
      await pump(tester);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2)),
      );
      verifyNever(
        () =>
            controller.animateCamera(any(), animation: any(named: 'animation')),
      );
    });

    testWidgets('tracks the position, zooming once', (tester) async {
      await pump(
        tester,
        tracking: UserLocationTracking.position,
        trackingZoom: 15,
      );
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 90),
      );
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 3, lat: 4), heading: 90),
      );
      const duration = Duration(milliseconds: 500);
      verifyInOrder([
        () => controller.animateCamera(
          const CameraUpdate.position(
            center: Geographic(lon: 1, lat: 2),
            zoom: 15,
          ),
          animation: const CameraAnimation.fly(duration: duration),
        ),
        () => controller.animateCamera(
          const CameraUpdate.position(center: Geographic(lon: 3, lat: 4)),
          animation: const CameraAnimation.fly(duration: duration),
        ),
      ]);
    });

    testWidgets('tracks the heading, from 1° on', (tester) async {
      await pump(tester, tracking: UserLocationTracking.positionAndHeading);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 90),
      );
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 90.5),
      );
      verify(
        () => controller.animateCamera(
          const CameraUpdate.position(
            center: Geographic(lon: 1, lat: 2),
            bearing: 90,
          ),
          animation: any(named: 'animation'),
        ),
      ).called(1);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2), heading: 91),
      );
      verify(
        () => controller.animateCamera(
          const CameraUpdate.position(
            center: Geographic(lon: 1, lat: 2),
            bearing: 91,
          ),
          animation: any(named: 'animation'),
        ),
      ).called(1);
    });

    testWidgets('moves to the last location when tracking starts', (
      tester,
    ) async {
      await pump(tester);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2)),
      );
      await pump(tester, tracking: UserLocationTracking.position);
      verify(
        () => controller.animateCamera(
          const CameraUpdate.position(center: Geographic(lon: 1, lat: 2)),
          animation: any(named: 'animation'),
        ),
      ).called(1);
    });

    testWidgets('a drag stops the tracking, a tap does not', (tester) async {
      await pump(tester, tracking: UserLocationTracking.position);
      await tester.tapAt(const Offset(400, 300));
      expect(trackingChanges, isEmpty);
      await tester.dragFrom(const Offset(400, 300), const Offset(100, 0));
      expect(trackingChanges, [UserLocationTracking.none]);
      clearInteractions(controller);
      await add(
        tester,
        const UserLocation(position: Geographic(lon: 1, lat: 2)),
      );
      verifyNever(
        () =>
            controller.animateCamera(any(), animation: any(named: 'animation')),
      );
    });

    testWidgets('a scroll wheel stops the tracking', (tester) async {
      await pump(tester, tracking: UserLocationTracking.position);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      expect(trackingChanges, [UserLocationTracking.none]);
    });

    testWidgets('lets pointers through to the map', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        App(
          camera: _camera,
          controller: controller,
          style: style.controller,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
            UserLocationLayer(locations: locations.stream),
          ],
        ),
      );
      await tester.tapAt(const Offset(400, 300));
      expect(taps, 1);
    });
  });

  group('paintCone', () {
    testWidgets('fades from the apex out, towards the top', (tester) async {
      final recorder = PictureRecorder();
      paintCone(
        Canvas(recorder),
        length: 50,
        halfAngle: 30,
        color: const Color(0xFF0000FF),
        opacity: 0.5,
      );
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(100, 100));
      final bytes = (await tester.runAsync(image!.toByteData))!;
      int alphaAt(int x, int y) => bytes.getUint8((y * 100 + x) * 4 + 3);
      // Up from the apex at (50, 50), fading out.
      final near = alphaAt(50, 45);
      final middle = alphaAt(50, 25);
      final far = alphaAt(50, 3);
      expect(near, closeTo(255 * 0.5, 16));
      expect(middle, lessThan(near));
      expect(far, lessThan(middle));
      expect(far, lessThan(16));
      // Nothing beside or below it, outside its 60°.
      expect(alphaAt(80, 50), 0);
      expect(alphaAt(50, 80), 0);
      expect(alphaAt(25, 20), 0);
      image.dispose();
      picture.dispose();
    });
  });
}
