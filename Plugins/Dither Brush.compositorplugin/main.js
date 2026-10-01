// Dither Brush: Compositor's first plugin, and an example of how one is written.
//
// plugin.json declares the brush and its options, and the patterns drawn as matrices or pictures. This script adds the
// patterns worked out in code, and says what the options do: which pattern the brush paints and in what colors, and
// how the Pencil's pressure sets its density and size.

// Bayer matrices, built as Aseprite builds them: each one is the matrix half its size, repeated four times in the order
// of the 2 × 2 one.
function bayer(n) {
  const d2 = [0, 2, 3, 1];
  function d(i, j, n) {
    if (n === 2) return d2[i * 2 + j];
    const half = n / 2;
    return 4 * d(i % half, j % half, half) + d(Math.floor(i / half), Math.floor(j / half), 2);
  }
  const rows = [];
  for (let i = 0; i < n; i++) {
    const row = [];
    for (let j = 0; j < n; j++) row.push(d(i, j, n));
    rows.push(row);
  }
  return rows;
}

for (const n of [2, 4, 8]) {
  compositor.registerPattern({ id: "bayer" + n, name: "Bayer " + n + " × " + n, matrix: bayer(n) });
}

compositor.registerBrush("dither", {
  // Once, as the options change: what the brush paints. Filling the gaps paints them the background color, so the
  // stroke dithers from one color to the other as Aseprite's dithered pressure does.
  ink(options) {
    return { pattern: options.pattern, colors: options.fillGaps ? "foregroundToBackground" : "foreground" };
  },

  // At each pressure, 0–1, from the lightest touch to the firmest (a mouse is always 1): how much of the pattern the
  // brush paints there, 0–1, and how big it is, as a fraction of its size. Pressure counts between Lightest and
  // Firmest, as in Aseprite's brush dynamics.
  dab(input, options) {
    const lightest = options.lightest / 100, firmest = options.firmest / 100;
    let p = input.pressure;
    if (p < lightest) p = 0;
    else if (p > firmest || lightest === firmest) p = 1;
    else p = (p - lightest) / (firmest - lightest);
    const density = options.density / 100;
    return {
      density: options.pressureDensity ? density * p : density,
      size: options.pressureSize ? p : 1,
    };
  },
});
