/ qmigrate — differ layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-30-differ-design.md
//
/ Compares a declared schema (section-6 rep) against an on-disk HDB.
/ Public (read disk): .qm.diff .qm.diffTable
/ Pure core:          .qm.i.compare .qm.i.rollupWith

\d .qm

/ severity ordering (low -> high)
i.sevRank:`ok`change`warning`destructive!0 1 2 3;

\d .
