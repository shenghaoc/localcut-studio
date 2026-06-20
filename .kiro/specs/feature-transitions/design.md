# Design: Transitions

> Status: **Proposed**. Depends on the custom compositor from [colour grading](../feature-colour-grading/design.md) for filter-based wipes.

## Approach

Model a `Transition` (id, type, duration) attached to the boundary between two adjacent clips on a track. In `CompositionBuilder`, place the two clips so they overlap by the transition duration, then emit an instruction for the overlap interval that ramps/combines the two layers:

- **Cross-dissolve**: opacity ramp — outgoing layer `setOpacityRamp(fromStartOpacity:1, toEndOpacity:0, timeRange:)`, incoming layer ramps `0→1`. No custom compositor required.
- **Wipe**: handled by `EffectCompositor`, which blends the two source frames via a Core Image transition (`CIBarsSwipeTransition` / a custom kernel) using the request time's progress through the overlap.

## Pieces

- **Model**: `Transition` value type; stored on `Track` keyed to the cut (or on the trailing clip). Overlap is derived, not stored, from neighbour durations.
- **Builder**: compute overlapping `timelineStart`s, ramp instructions for dissolve, compositor metadata for wipe; ensure non-overlapping instruction segmentation still holds outside the transition interval.
- **UI**: transition affordance drawn at the cut; toolbar/menu/context action to add; inspector for type + duration; delete restores the cut by removing the overlap.

## Risks

- Keeping instruction segmentation valid when clips intentionally overlap — the overlap interval is its own instruction.
- Duration clamping must react to later trims that shrink a neighbour below the transition length.
