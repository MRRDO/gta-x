// BeamNG world meters <-> map coordinates, for the app's MapLibre map and nav stores.
// BeamNG levels are flat meters (x east, y north). The app's map wants [lat, lon],
// so we pin the level to a spot on Earth and use a local flat projection
// (accurate to centimeters over a level-sized area).

import type { MapInfo, Route, Traffic, Vec3 } from '../protocol.ts'

export type GeoOrigin = { lat: number; lon: number }

/** Where level origins sit on Earth. West Coast USA goes near the Bay Area; anything else defaults there too. */
export const LEVEL_ORIGINS: Record<string, GeoOrigin> = {
  west_coast_usa: { lat: 37.39, lon: -122.08 },
  italy: { lat: 44.1, lon: 9.8 },
  east_coast_usa: { lat: 41.0, lon: -74.3 },
  utah: { lat: 38.6, lon: -109.6 },
}
export const DEFAULT_ORIGIN: GeoOrigin = LEVEL_ORIGINS.west_coast_usa

const M_PER_DEG_LAT = 111_320

export function originFor(level?: string | null): GeoOrigin {
  return (level && LEVEL_ORIGINS[level]) || DEFAULT_ORIGIN
}

/** World meters -> [lat, lon] (the nav store's order). */
export function worldToLatLon(x: number, y: number, o: GeoOrigin = DEFAULT_ORIGIN): [number, number] {
  const lat = o.lat + y / M_PER_DEG_LAT
  const lon = o.lon + x / (M_PER_DEG_LAT * Math.cos((o.lat * Math.PI) / 180))
  return [lat, lon]
}

/** World meters -> [lon, lat] (GeoJSON / MapLibre order). */
export function worldToLngLat(x: number, y: number, o: GeoOrigin = DEFAULT_ORIGIN): [number, number] {
  const [lat, lon] = worldToLatLon(x, y, o)
  return [lon, lat]
}

/** [lon, lat] (e.g. a MapLibre click) -> world meters. z comes from the nearest road node when a map is given. */
export function lngLatToWorld(lon: number, lat: number, o: GeoOrigin = DEFAULT_ORIGIN, map?: MapInfo | null): Vec3 {
  const x = (lon - o.lon) * M_PER_DEG_LAT * Math.cos((o.lat * Math.PI) / 180)
  const y = (lat - o.lat) * M_PER_DEG_LAT
  let z = 0
  if (map) {
    let best = Infinity
    for (const n of map.nodes) {
      const d = (n.pos[0] - x) ** 2 + (n.pos[1] - y) ** 2
      if (d < best) { best = d; z = n.pos[2] }
    }
  }
  return [x, y, z]
}

/** Compass heading in degrees (0 = north, 90 = east) from a BeamNG direction vector. */
export function headingDeg(dir: Vec3 | [number, number]): number {
  const h = (Math.atan2(dir[0], dir[1]) * 180) / Math.PI
  return (h + 360) % 360
}

export const MPS_TO_MPH = 2.2369363

/** Driving-view meters (the app's WorldRoads: X = -east, Z = north) relative to the car. */
export function worldToDriveView(p: Vec3 | [number, number], car: Vec3): [number, number] {
  return [-(p[0] - car[0]), p[1] - car[1]]
}

// ---------------------------------------------------------------- GeoJSON for MapLibre

type Feature = { type: 'Feature'; properties: Record<string, unknown>; geometry: { type: string; coordinates: unknown } }
type FC = { type: 'FeatureCollection'; features: Feature[] }

/** Road graph as lines, with `width` (m), `oneWay`, `speedLimit` (m/s) properties. */
export function roadsGeoJSON(map: MapInfo, o: GeoOrigin = originFor(map.level)): FC {
  const nodes = new Map(map.nodes.map((n) => [n.id, n]))
  const features: Feature[] = []
  for (const l of map.links) {
    const a = nodes.get(l.a), b = nodes.get(l.b)
    if (!a || !b) continue
    features.push({
      type: 'Feature',
      properties: { width: a.radius + b.radius, oneWay: l.oneWay, speedLimit: l.speedLimit, drivability: l.drivability, name: l.name ?? '' },
      geometry: { type: 'LineString', coordinates: [worldToLngLat(a.pos[0], a.pos[1], o), worldToLngLat(b.pos[0], b.pos[1], o)] },
    })
  }
  return { type: 'FeatureCollection', features }
}

export function routeGeoJSON(route: Route | null, o: GeoOrigin = DEFAULT_ORIGIN): FC {
  if (!route || route.points.length < 2) return { type: 'FeatureCollection', features: [] }
  return {
    type: 'FeatureCollection',
    features: [{ type: 'Feature', properties: { length: route.length }, geometry: { type: 'LineString', coordinates: route.points.map((p) => worldToLngLat(p[0], p[1], o)) } }],
  }
}

export function trafficGeoJSON(cars: Traffic['cars'], o: GeoOrigin = DEFAULT_ORIGIN): FC {
  return {
    type: 'FeatureCollection',
    features: cars.map((c) => ({
      type: 'Feature',
      properties: { id: c.id, heading: headingDeg(c.dir), speedMph: c.speed * MPS_TO_MPH, w: c.w, l: c.l },
      geometry: { type: 'Point', coordinates: worldToLngLat(c.pos[0], c.pos[1], o) },
    })),
  }
}

/** Route in the nav store's shape: coords as [lon, lat][]. */
export function routeCoords(route: Route | null, o: GeoOrigin = DEFAULT_ORIGIN): [number, number][] {
  return route ? route.points.map((p) => worldToLngLat(p[0], p[1], o)) : []
}
