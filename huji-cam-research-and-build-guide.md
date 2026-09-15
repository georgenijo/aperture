# Historical inspiration: disposable-camera apps

This is research context, not a specification or an assertion that Aperture copied any app, asset, brand, font, or implementation. Competitive facts can change; treat them as historical inspiration and re-check them before making product or legal claims.

## What informed the product direction

Public descriptions of Huji Cam and adjacent disposable-camera apps popularized a recognizable ritual: a constrained viewfinder, simple shutter, delayed “development,” a private roll/Lab, date marks, grain, warm color response, and occasional light leaks. Other apps explored fixed shot counts, multiple camera personalities, social rolls, or video. The useful lesson is experiential: the limitation and the reveal can be part of the camera, not merely a post-processing preset.

Aperture deliberately keeps the ritual while adding camera controls and a local, recoverable archive. Its names, UI, recipes, parameters, and generated output are its own; do not add third-party branded packaging or copied overlays.

## Technical inspiration, translated into current code

The familiar film vocabulary maps to ordinary on-device operations: tone/color response, bloom, softness, seeded grain, optional light leak, chromatic aberration, vignette, and date stamp. Aperture implements these in a versioned Core Image pipeline driven by a persisted `AppliedFilmRecipe`; it does not use a copied LUT or a downloaded overlay library. Random-looking choices are seeded so a developed item can be retried identically.

The camera is native AVFoundation rather than a cross-platform abstraction. A virtual multi-camera device is mapped to display stops from its actual switch-over factors and native resolution factors. Storage is an actor-isolated local library with staging, recovery, atomic metadata, replacement reconciliation, and migration from the project’s earlier `Documents/photos` format. Legacy deletion tombstones are durable and a corrupt ledger pauses migration safely; these are Aperture implementation details, not claims about the historical apps.

## Research guardrails

- External download counts, pricing, ownership, feature lists, and “how it is built” claims are historical leads, not current verified facts.
- Never describe an effect as an exact reproduction of a named commercial film stock without licensed source material and validation.
- Do not ship copied logos, packaging, fonts, screenshots, sound, light-leak PNGs, or other branded assets.
- Aperture’s short-film mode is implemented; social layers, cloud sync, and monetization remain outside the current scope. See [ROADMAP.md](ROADMAP.md).
