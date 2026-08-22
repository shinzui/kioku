---
type: Architecture Decision Record
title: Consumers own one-time foreign event migration codecs
description: >-
  Kioku's normal codecs decode Kioku history, while a consumer that must translate another
  application's wire format owns a finite migration codec and retires it after an evidenced
  cutover or explicit support decision.
timestamp: 2026-08-22T15:48:53Z
docId: ADR-11
status: accepted
date: 2026-08-22
---

# Consumers own one-time foreign event migration codecs

## Status

Accepted, 2026-08-22.

## Context

Kioku's public memory and session event parsers once had two arms. The first decoded Kioku's own
event language. The second recognized event tags, identifiers, scopes, and focus values from Rei's
older agent-memory implementation and translated them into Kioku values. That fallback made a
one-time adoption path available through every ordinary replay forever.

The two histories do not have the same owner. Kioku must continue to replay native events written
by older Kioku versions, including events from before memory-space partitioning and session-resume
events written before the `force` field existed. Rei's retired wire protocol is foreign history:
only Rei can decide whether it should be copied, retained without support, or deleted under a
separate retention policy.

A permanent producer-owned fallback also hides the real operational gate. Its Haskell type stays
unchanged while its accepted language expands, so a consumer can depend on the behavior without a
package solver or compiler exposing that dependency.

## Decision

Kioku's normal event codecs decode Kioku history only. Native compatibility rules and upcasts
remain in Kioku for as long as their durable history can exist; they are not classified as foreign
merely because an old payload omits fields now required on new writes.

A consumer that needs to translate another application's event language owns that translation in
a finite migration tool or consumer-side compatibility component. The tool may use Kioku domain
constructors and native encoders, but the foreign tag dispatch, identifier normalization, and
policy defaults do not live in `Kioku.Memory.EventStream` or `Kioku.Session.EventStream`.

Retiring a foreign codec requires evidence for all of the following:

1. current dependents have been discovered from the registered dependency graph and inspected for
   behavioral use, not inferred safe from version bounds alone;
2. the consumer has either migrated the history or explicitly abandoned support after preserving
   whatever inventory and recovery boundary its retention decision requires;
3. no deployable consumer still imports or invokes the foreign decoder; and
4. the accepted-language narrowing is released as a breaking version change even when the parser
   type is unchanged.

Rei satisfied this boundary by retaining its raw history and a fully restored database backup,
recording an explicit support-abandonment decision, and deleting the migrator and its Kioku parser
imports. The detailed execution evidence remains with
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`.

## Consequences

The public parser signatures remain `Value -> Either Text Event`, but values from Rei's retired
`agent_*` language now return `Left`. A caller that still needs those values must keep or recover a
consumer-owned decoder rather than expecting an ordinary Kioku replay to translate them.

Kioku's native pre-partition payloads continue to land in `kioku_legacy`, and pre-`force` resume
payloads keep their established defaulting. The words "legacy" and "native compatibility" remain
valid for Kioku's own history; this decision removes only foreign application vocabulary.

Consumer cutover evidence is deliberately outcome-oriented. Copying foreign events into native
streams is one valid outcome, but an explicit decision to retain the source bytes without ongoing
support is also valid when the consumer owns that product tradeoff and preserves its chosen
recovery boundary.

Future integrations cannot add a permanent consumer-specific fallback to the normal codec as a
shortcut. They must make the migration lifecycle and retirement gate visible at the consumer
boundary.

## Alternatives rejected

**Keep the fallback because its public type is stable.** Rejected: accepted input is observable
behavior, and maintaining a second application's protocol indefinitely is not type-level
compatibility.

**Require every consumer to copy every foreign event before retirement.** Rejected: Kioku needs
proof that no live caller depends on the decoder, but only the consumer can value the history and
choose between migration, unsupported retention, and deletion.

**Remove all old-payload defaults together.** Rejected: native Kioku history is Kioku's durable
compatibility responsibility. Foreign ownership is not a reason to strand Kioku's own streams.

## References

- [ExecPlan 39](../plans/39-retire-rei-legacy-event-decoders-after-consumer-cutover.md)
- [ADR-3](legacy-data-lands-in-one-explicit-space.md)
- [ADR-5](historical-attribution-is-marked-never-invented.md)
- `mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`
