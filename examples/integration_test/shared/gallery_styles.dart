import 'dart:convert';

import 'gallery_data.dart';
import 'gallery_places.dart';

/// The two outdoor looks of the gallery.
enum GalleryLook {
  fieldTopo('field-topo'),
  trueEarth('true-earth');

  const GalleryLook(this.slug);
  final String slug;
}

const _libertyLabels = 'label_|water_name|highway-name';

/// The True Earth sky, which the native engine ignores until it can draw one.
const Map<String, Object> trueEarthSky = {
  'sky-color': '#3E7CC0',
  'horizon-color': '#DCE7EF',
  'fog-color': '#C6D4E0',
  'sky-horizon-blend': 0.85,
  'horizon-fog-blend': 0.75,
  'fog-ground-blend': 0.35,
  'atmosphere-blend': 0.9,
};

/// The style JSON of [look] at [place].
///
/// The sources come in as parameters, so that the same styles can point at
/// another server: [demUrl] is a terrarium tile template, [basemapTileJson]
/// the TileJSON URL of an OpenMapTiles source, and [imageryUs] and
/// [imageryWorld] raster tile templates.
String galleryStyle(
  GalleryLook look,
  GalleryPlace place, {
  required String demUrl,
  required String basemapTileJson,
  required String imageryUs,
  required String imageryWorld,
}) {
  final fieldTopo = look == GalleryLook.fieldTopo;
  final trails = place.name == 'Yosemite';
  final sources = <String, Object?>{
    'openmaptiles': {'type': 'vector', 'url': basemapTileJson},
    'dem': {
      'type': 'raster-dem',
      'tiles': [demUrl],
      'encoding': 'terrarium',
      'tileSize': 512,
      'maxzoom': 14,
    },
    if (fieldTopo)
      'demhs': {
        'type': 'raster-dem',
        'tiles': [demUrl],
        'encoding': 'terrarium',
        'tileSize': 512,
        'maxzoom': 14,
      },
    if (!fieldTopo)
      'sat': place.inUs
          ? {
              'type': 'raster',
              'tiles': [imageryUs],
              'tileSize': 256,
              'maxzoom': 16,
            }
          : {
              'type': 'raster',
              'tiles': [imageryWorld],
              'tileSize': 256,
              'maxzoom': 15,
            },
    if (trails)
      'trails': {'type': 'geojson', 'data': jsonDecode(yosemiteTrailsJson)},
  };
  final liberty = (jsonDecode(libertyLayersJson) as List)
      .cast<Map<String, dynamic>>();
  final layers = fieldTopo
      ? _fieldTopoLayers(liberty)
      : _trueEarthLayers(liberty);
  layers.addAll(_pathLayers(fieldTopo));
  if (trails) layers.addAll(_trailLayers(fieldTopo));
  return jsonEncode({
    'version': 8,
    'glyphs': libertyGlyphs,
    'sprite': libertySprite,
    'sources': sources,
    'layers': layers,
    'terrain': {'source': 'dem', 'exaggeration': 1.0},
    if (!fieldTopo) 'sky': trueEarthSky,
  });
}

List<Map<String, dynamic>> _fieldTopoLayers(
  List<Map<String, dynamic>> liberty,
) {
  final layers = <Map<String, dynamic>>[];
  for (final l in liberty) {
    final id = l['id'] as String;
    final type = l['type'] as String;
    final paint = (l['paint'] as Map<String, dynamic>?) ?? {};
    void fill(RegExp re, String color, [double? opacity]) {
      if (type == 'fill' && re.hasMatch(id)) {
        paint['fill-color'] = color;
        if (opacity != null) paint['fill-opacity'] = opacity;
      }
    }

    if (type == 'background') paint['background-color'] = '#f2efe6';
    fill(RegExp('wood|forest'), '#cfe0b8');
    fill(RegExp('grass|park'), '#e3ecd0');
    fill(RegExp(r'^water$'), '#9fc9e8');
    fill(RegExp('sand|beach'), '#F3E9C9');
    fill(RegExp('wetland'), '#D6E8DC', 0.8);
    fill(RegExp('farmland|agriculture'), '#EEF0D8');
    fill(RegExp('ice|glacier'), '#D4EAF8', 0.9);
    fill(RegExp('rock|bare'), '#CFC7BB', 0.6);
    l['paint'] = paint;
    layers.add(l);
  }
  final firstSymbol = layers.indexWhere((l) => l['type'] == 'symbol');
  layers.insert(firstSymbol, {
    'id': 'hs',
    'type': 'hillshade',
    'source': 'demhs',
    'paint': {
      'hillshade-shadow-color': '#5a5040',
      'hillshade-highlight-color': '#fffaf0',
      'hillshade-accent-color': '#7a6a50',
      'hillshade-exaggeration': 0.55,
      'hillshade-illumination-direction': 315,
      'hillshade-illumination-anchor': 'map',
    },
  });
  return layers;
}

List<Map<String, dynamic>> _trueEarthLayers(
  List<Map<String, dynamic>> liberty,
) {
  final layers = <Map<String, dynamic>>[
    {
      'id': 'bg',
      'type': 'background',
      'paint': {'background-color': '#2b2f2a'},
    },
    {
      'id': 'sat',
      'type': 'raster',
      'source': 'sat',
      'paint': {'raster-saturation': 0.1, 'raster-contrast': 0.08},
    },
  ];
  for (final l in liberty) {
    final id = l['id'] as String;
    if (l['type'] == 'symbol' && RegExp(_libertyLabels).hasMatch(id)) {
      if (id.startsWith('highway-name')) continue;
      l['paint'] = {
        ...?(l['paint'] as Map<String, dynamic>?),
        'text-color': '#FFFFFF',
        'text-halo-color': 'rgba(0,0,0,0.6)',
        'text-halo-width': 1.5,
      };
      layers.add(l);
    }
  }
  return layers;
}

/// Every footpath of OSM, drawn as a trail.
List<Map<String, dynamic>> _pathLayers(bool light) {
  const notFootway = [
    '!',
    [
      'in',
      ['get', 'subclass'],
      [
        'literal',
        ['footway', 'cycleway', 'steps', 'pedestrian', 'sidewalk'],
      ],
    ],
  ];
  const isPath = [
    'in',
    ['get', 'class'],
    [
      'literal',
      ['path', 'track'],
    ],
  ];
  final width = [
    'interpolate',
    ['linear'],
    ['zoom'],
    12,
    0.8,
    16,
    2.2,
  ];
  return [
    {
      'id': 'osm-paths-cas',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'minzoom': 12,
      'filter': ['all', isPath, notFootway],
      'paint': {
        'line-color': light ? 'rgba(255,255,255,0.8)' : 'rgba(0,0,0,0.35)',
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          12,
          1.5,
          16,
          4,
        ],
      },
    },
    {
      'id': 'osm-paths',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'minzoom': 12,
      'filter': ['all', isPath, notFootway],
      'paint': {
        'line-color': light ? '#B5463E' : '#FFD9B8',
        'line-width': width,
        'line-dasharray': [2.5, 1.5],
      },
    },
  ];
}

/// The Yosemite fixture: Half Dome and Snow Creek in colour, the rest dimmed.
List<Map<String, dynamic>> _trailLayers(bool light) {
  const active = ['Half Dome Trail', 'Snow Creek Trail'];
  final casing = light ? '#ffffff' : 'rgba(0,0,0,0.55)';
  final core = light ? '#e2372b' : '#FFD23F';
  return [
    {
      'id': 'trails-other',
      'type': 'line',
      'source': 'trails',
      'filter': [
        '!',
        [
          'in',
          ['get', 'name'],
          ['literal', active],
        ],
      ],
      'layout': {'line-join': 'round'},
      'paint': {
        'line-color': light ? '#B5463E' : '#FFC8A8',
        'line-width': 1.4,
        'line-dasharray': [2, 1.5],
        'line-opacity': 0.8,
      },
    },
    for (final (id, color, w1, w2) in [
      ('act-cas', casing, 5, 11),
      ('act', core, 2.8, 7),
    ])
      {
        'id': id,
        'type': 'line',
        'source': 'trails',
        'filter': [
          'in',
          ['get', 'name'],
          ['literal', active],
        ],
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {
          'line-color': color,
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            11,
            w1,
            16,
            w2,
          ],
        },
      },
  ];
}
