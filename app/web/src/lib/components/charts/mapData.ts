// Bundled, offline geography for the `map` result block (a proportional-symbol /
// bubble map). NO external map library, tiles, CDN, or remote GeoJSON — the app is
// self-contained, same constraint as the other charts. We ship two compact, low-res
// outlines drawn as normalized polylines, plus a centroid lookup per place code:
//   - level "country": ISO-3166 alpha-3 codes (USA, GBR, ROU, …) placed by an
//     equirectangular projection of a hand-entered lon/lat table over a cropped
//     world box. The world landmass outline is coarse continent polygons projected
//     the same way, so a bubble lands on/near its country.
//   - level "state": US 2-letter codes placed by an equirectangular projection of a
//     continental-US lon/lat table; Alaska + Hawaii are hand-placed as a lower-left
//     inset (the standard US-map convention). The US border outline is projected the
//     same way.
// Everything is emitted as normalized [x, y] in [0, 1] (y = 0 at top) so the chart
// only has to scale to its viewBox — one code path for both levels.

export type XY = [number, number];

// ── equirectangular projection → normalized [0,1] ────────────────────────────
interface Box {
  lonMin: number;
  lonMax: number;
  latMin: number;
  latMax: number;
}
function project(lon: number, lat: number, b: Box): XY {
  const x = (lon - b.lonMin) / (b.lonMax - b.lonMin);
  const y = (b.latMax - lat) / (b.latMax - b.latMin); // lat↑ → y↓ (top)
  return [x, y];
}
function projectAll(lls: [number, number][], b: Box): XY[] {
  return lls.map(([lon, lat]) => project(lon, lat, b));
}
function projectMap(
  table: Record<string, [number, number]>,
  b: Box,
): Record<string, XY> {
  const out: Record<string, XY> = {};
  for (const k in table) out[k] = project(table[k][0], table[k][1], b);
  return out;
}

// ── WORLD (country level) ────────────────────────────────────────────────────
// Cropped to drop most of Antarctica / far-north emptiness so the map fills the box.
const WORLD: Box = { lonMin: -170, lonMax: 190, latMin: -56, latMax: 78 };

// Coarse continent outlines as [lon, lat] rings — recognizable, not precise.
const WORLD_LL: [number, number][][] = [
  // North America
  [
    [-168, 65], [-150, 70], [-125, 70], [-95, 72], [-81, 73], [-60, 60],
    [-52, 47], [-70, 42], [-81, 25], [-97, 25], [-97, 16], [-105, 20],
    [-110, 30], [-124, 40], [-125, 48], [-135, 58], [-150, 60], [-168, 65],
  ],
  // Greenland
  [
    [-45, 60], [-42, 66], [-30, 70], [-20, 70], [-22, 76], [-40, 78],
    [-55, 76], [-52, 68], [-45, 60],
  ],
  // South America
  [
    [-80, 8], [-60, 10], [-50, 0], [-35, -5], [-40, -23], [-48, -30],
    [-58, -35], [-65, -45], [-70, -54], [-73, -45], [-71, -30], [-70, -18],
    [-81, -5], [-80, 2], [-80, 8],
  ],
  // Africa
  [
    [-10, 35], [10, 37], [25, 32], [35, 31], [43, 11], [51, 12], [40, -5],
    [40, -20], [32, -27], [25, -34], [18, -34], [12, -18], [9, 0], [5, 5],
    [-5, 5], [-17, 15], [-16, 22], [-10, 28], [-10, 35],
  ],
  // Europe (mainland)
  [
    [-10, 36], [3, 42], [8, 44], [18, 40], [23, 38], [28, 41], [30, 45],
    [30, 60], [28, 70], [12, 65], [5, 60], [8, 54], [0, 51], [-5, 48],
    [-9, 44], [-10, 36],
  ],
  // Great Britain + Ireland (coarse single blob)
  [
    [-6, 50], [1, 51], [-1, 53], [-3, 55], [-6, 58], [-10, 55], [-8, 52],
    [-6, 50],
  ],
  // Asia
  [
    [30, 45], [30, 60], [28, 66], [60, 73], [100, 76], [140, 73], [170, 68],
    [160, 60], [155, 52], [140, 50], [135, 35], [122, 30], [108, 18],
    [100, 7], [95, 15], [88, 22], [80, 8], [73, 18], [68, 24], [57, 25],
    [48, 30], [44, 38], [35, 40], [30, 45],
  ],
  // Japan (coarse)
  [
    [130, 33], [138, 35], [141, 40], [140, 43], [136, 37], [132, 34], [130, 33],
  ],
  // Australia
  [
    [114, -22], [122, -18], [130, -12], [142, -11], [146, -19], [153, -28],
    [150, -37], [140, -38], [129, -32], [115, -34], [114, -22],
  ],
  // New Zealand (coarse)
  [
    [173, -35], [178, -38], [176, -41], [168, -46], [167, -44], [173, -40],
    [173, -35],
  ],
];

// ISO-3166 alpha-3 → approximate [lon, lat] centroid.
const COUNTRY_LL: Record<string, [number, number]> = {
  USA: [-98, 39], CAN: [-106, 56], MEX: [-102, 23], GTM: [-90, 15],
  BRA: [-51, -10], ARG: [-64, -34], CHL: [-71, -30], COL: [-73, 4],
  PER: [-75, -10], VEN: [-66, 7], BOL: [-64, -17], ECU: [-78, -1],
  URY: [-56, -33], PRY: [-58, -23],
  GBR: [-1.5, 52], IRL: [-8, 53], FRA: [2, 46], ESP: [-4, 40], PRT: [-8, 39.5],
  DEU: [10, 51], ITA: [12, 42], NLD: [5.5, 52], BEL: [4.5, 50.5], CHE: [8, 47],
  AUT: [14, 47.5], POL: [19, 52], SWE: [15, 62], NOR: [9, 61], FIN: [26, 64],
  DNK: [10, 56], ROU: [25, 46], GRC: [22, 39], TUR: [35, 39], RUS: [90, 62],
  UKR: [31, 49], CZE: [15, 49.8], HUN: [19, 47], ISL: [-19, 65],
  CHN: [104, 35], JPN: [138, 37], KOR: [128, 36], IND: [79, 22], IDN: [113, -2],
  THA: [101, 15], VNM: [106, 16], PHL: [122, 12], MYS: [102, 4], SGP: [104, 1.3],
  PAK: [70, 30], BGD: [90, 24], SAU: [45, 24], ARE: [54, 24], ISR: [35, 31],
  IRN: [53, 32], IRQ: [44, 33], TWN: [121, 24], HKG: [114, 22],
  EGY: [30, 27], ZAF: [24, -29], NGA: [8, 10], KEN: [38, 0], MAR: [-6, 32],
  DZA: [3, 28], ETH: [40, 8], GHA: [-1, 8], TZA: [35, -6], TUN: [9, 34],
  AUS: [134, -25], NZL: [172, -42],
};

const COUNTRY_NAMES: Record<string, string> = {
  USA: "United States", CAN: "Canada", MEX: "Mexico", GTM: "Guatemala",
  BRA: "Brazil", ARG: "Argentina", CHL: "Chile", COL: "Colombia", PER: "Peru",
  VEN: "Venezuela", BOL: "Bolivia", ECU: "Ecuador", URY: "Uruguay", PRY: "Paraguay",
  GBR: "United Kingdom", IRL: "Ireland", FRA: "France", ESP: "Spain",
  PRT: "Portugal", DEU: "Germany", ITA: "Italy", NLD: "Netherlands",
  BEL: "Belgium", CHE: "Switzerland", AUT: "Austria", POL: "Poland",
  SWE: "Sweden", NOR: "Norway", FIN: "Finland", DNK: "Denmark", ROU: "Romania",
  GRC: "Greece", TUR: "Turkey", RUS: "Russia", UKR: "Ukraine", CZE: "Czechia",
  HUN: "Hungary", ISL: "Iceland", CHN: "China", JPN: "Japan", KOR: "South Korea",
  IND: "India", IDN: "Indonesia", THA: "Thailand", VNM: "Vietnam",
  PHL: "Philippines", MYS: "Malaysia", SGP: "Singapore", PAK: "Pakistan",
  BGD: "Bangladesh", SAU: "Saudi Arabia", ARE: "United Arab Emirates",
  ISR: "Israel", IRN: "Iran", IRQ: "Iraq", TWN: "Taiwan", HKG: "Hong Kong",
  EGY: "Egypt", ZAF: "South Africa", NGA: "Nigeria", KEN: "Kenya",
  MAR: "Morocco", DZA: "Algeria", ETH: "Ethiopia", GHA: "Ghana",
  TZA: "Tanzania", TUN: "Tunisia", AUS: "Australia", NZL: "New Zealand",
};

// ── UNITED STATES (state level) ──────────────────────────────────────────────
const US: Box = { lonMin: -125, lonMax: -66, latMin: 24, latMax: 50 };

// Coarse continental-US border ring as [lon, lat] (the northern Great-Lakes edge is
// simplified to a near-straight border for a low-res backdrop).
const US_LL: [number, number][][] = [
  [
    [-124, 48], [-124, 42], [-124, 40], [-122, 37], [-118, 34], [-117, 32.5],
    [-114, 32.5], [-111, 31.3], [-108, 31.3], [-106, 32], [-103, 29], [-99, 27],
    [-97, 26], [-97, 28], [-94, 29], [-89, 29], [-88, 30], [-84, 30], [-81, 25],
    [-80, 27], [-81, 32], [-76, 35], [-75, 37], [-74, 39], [-71, 41], [-70, 43],
    [-67, 45], [-69, 47], [-83, 42], [-83, 46], [-90, 48], [-95, 49], [-104, 49],
    [-123, 49], [-124, 48],
  ],
];

// Continental-state centroids as [lon, lat]; AK + HI are added below as insets.
const STATE_LL: Record<string, [number, number]> = {
  AL: [-86.8, 32.8], AZ: [-111.7, 34.3], AR: [-92.4, 34.9], CA: [-119.7, 37.2],
  CO: [-105.5, 39], CT: [-72.7, 41.6], DE: [-75.5, 39], FL: [-81.7, 28.6],
  GA: [-83.4, 32.7], ID: [-114.6, 44.4], IL: [-89.2, 40], IN: [-86.3, 39.9],
  IA: [-93.5, 42], KS: [-98.4, 38.5], KY: [-85.3, 37.5], LA: [-92, 31],
  ME: [-69.2, 45.4], MD: [-76.7, 39], MA: [-71.8, 42.3], MI: [-85, 44.3],
  MN: [-94.3, 46.3], MS: [-89.7, 32.7], MO: [-92.5, 38.4], MT: [-109.6, 47],
  NE: [-99.8, 41.5], NV: [-116.9, 39.3], NH: [-71.6, 43.7], NJ: [-74.5, 40.2],
  NM: [-106, 34.4], NY: [-75.5, 42.9], NC: [-79.4, 35.5], ND: [-100.3, 47.5],
  OH: [-82.8, 40.2], OK: [-97.5, 35.6], OR: [-120.5, 44], PA: [-77.8, 40.9],
  RI: [-71.5, 41.7], SC: [-80.9, 33.9], SD: [-100.2, 44.4], TN: [-86.4, 35.9],
  TX: [-99.3, 31.5], UT: [-111.7, 39.3], VT: [-72.7, 44.1], VA: [-78.5, 37.5],
  WA: [-120.4, 47.4], WV: [-80.6, 38.6], WI: [-89.9, 44.6], WY: [-107.5, 43],
  DC: [-77, 38.9],
};

const STATE_NAMES: Record<string, string> = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California",
  CO: "Colorado", CT: "Connecticut", DE: "Delaware", FL: "Florida", GA: "Georgia",
  HI: "Hawaii", ID: "Idaho", IL: "Illinois", IN: "Indiana", IA: "Iowa",
  KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland",
  MA: "Massachusetts", MI: "Michigan", MN: "Minnesota", MS: "Mississippi",
  MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada", NH: "New Hampshire",
  NJ: "New Jersey", NM: "New Mexico", NY: "New York", NC: "North Carolina",
  ND: "North Dakota", OH: "Ohio", OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania",
  RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota", TN: "Tennessee",
  TX: "Texas", UT: "Utah", VT: "Vermont", VA: "Virginia", WA: "Washington",
  WV: "West Virginia", WI: "Wisconsin", WY: "Wyoming", DC: "Washington, D.C.",
};

// ── exported, projected geography ────────────────────────────────────────────
export interface MapGeo {
  outline: XY[][]; // filled landmass/border rings, normalized [0,1]
  centroids: Record<string, XY>; // place code → normalized [0,1] position
  names: Record<string, string>; // place code → display name
  aspect: number; // width / height of the projected box (keeps geography un-stretched)
}

function boxAspect(b: Box): number {
  return (b.lonMax - b.lonMin) / (b.latMax - b.latMin);
}

const countryCentroids = projectMap(COUNTRY_LL, WORLD);

// Alaska + Hawaii float as a lower-left inset (they'd project far off the
// continental box otherwise) — the standard US-map treatment.
const stateCentroids: Record<string, XY> = {
  ...projectMap(STATE_LL, US),
  AK: [0.06, 0.93],
  HI: [0.16, 0.95],
};

export const COUNTRY_GEO: MapGeo = {
  outline: WORLD_LL.map((ring) => projectAll(ring, WORLD)),
  centroids: countryCentroids,
  names: COUNTRY_NAMES,
  aspect: boxAspect(WORLD),
};

export const STATE_GEO: MapGeo = {
  outline: US_LL.map((ring) => projectAll(ring, US)),
  centroids: stateCentroids,
  names: STATE_NAMES,
  aspect: boxAspect(US),
};

export function geoFor(level: "country" | "state"): MapGeo {
  return level === "state" ? STATE_GEO : COUNTRY_GEO;
}
