"""Deterministic, session-only step adaptation (SUB-03/04) and timer suggestions. Pure.

An approved swap rewrites only the steps whose ``ingredient_refs`` include the swapped
ingredient: every mention of the ingredient is replaced by the replacement text (longest
phrase first, plurals included, never inside a longer mention of *another* ingredient of the
same step). A step that references the ingredient without naming it gets an explicit
annotation instead. The published version is never touched; the original text travels with
the adapted one.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass

from app.domains.matching.dictionary import (
    DictEntry,
    IngredientDictionary,
    clean,
    pluralize_phrase,
)
from app.domains.matching.normalize import DESCRIPTORS, alternatives, normalize
from app.domains.recipes.schemas import IngredientOut, StepOut
from app.domains.safety.content import known_food

_PAREN_RE = re.compile(r"\(([^)]*)\)")
# A bare generic head word never stands for a specific ingredient: "the oil" in a step with
# neutral oil is not rewritten (only "neutral oil" is); it gets an annotation instead.
GENERIC_HEADS = frozenset(
    {
        "oil",
        "sauce",
        "juice",
        "paste",
        "powder",
        "seeds",
        "seed",
        "leaves",
        "leaf",
        "wine",
        "vinegar",
        "flakes",
        "milk",
        "cream",
        "stock",
        "broth",
        "syrup",
        "water",
        "mix",
        "spice",
        "spices",
        "cheese",
        "flour",
        "meat",
        "zest",
        "extract",
    }
)
_AMOUNT_BEFORE_RE = re.compile(
    r"(\d+(?:[./]\d+)?|\ba|\ban|\bone|\btwo|\bthree|\bhalf|\bquarter)\s+"
    r"(?:(?:tbsp|tsp|tablespoons?|teaspoons?|cups?|g|grams?|ml|oz|ounces?|lbs?|pounds?|cloves?|"
    r"pinch(?:es)?|splash(?:es)?|dash(?:es)?|handfuls?|sprigs?)\s+)?(?:of\s+)?(?:the\s+)?$",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class AdaptationSpec:
    id: str
    ingredient_ref: str
    original: str
    replacement: str
    ratio_or_amount: str | None = None


def mention_phrases(name: str, dictionary: IngredientDictionary) -> list[str]:
    """Phrases that refer to ingredient ``name`` in step text, longest first."""
    phrases: set[str] = set()
    sources = [clean(name), *alternatives(name)]
    for source in sources:
        inner = [p.strip() for p in _PAREN_RE.findall(source) if p.strip()]
        base = re.sub(r"\s+", " ", _PAREN_RE.sub(" ", source)).strip(" ,")
        for chunk in (base, *inner):
            entry = normalize(chunk, dictionary).entry
            words = [w for w in chunk.split(" ") if w]
            stripped = [w for w in words if w not in DESCRIPTORS] or words
            for seq in (words, stripped):
                if not seq:
                    continue
                for k in range(1, len(seq) + 1):  # suffixes: "sesame oil" (never bare "oil")
                    suffix = " ".join(seq[-k:])
                    if k < len(seq) and k == 1 and suffix in GENERIC_HEADS:
                        continue
                    phrases.add(suffix)
                for i in range(len(seq)):
                    for j in range(i + 1, len(seq) + 1):
                        gram = " ".join(seq[i:j])
                        if _same_food(dictionary.lookup(gram), entry):
                            phrases.add(gram)  # "chicken" in "chicken thighs"
            if entry is not None:
                phrases.add(entry.canonical_name)
                phrases.update(a for a in entry.aliases if len(a) > 2)
    phrases.discard("")
    with_plurals = set(phrases)
    for p in phrases:
        with_plurals.update(pluralize_phrase(p))
    return sorted(with_plurals, key=lambda p: (-len(p), p))


def _same_food(gram: DictEntry | None, whole: DictEntry | None) -> bool:
    """An inner phrase names the same food as the whole name, or a generic name for it
    ("chicken" for chicken thigh); "kimchi" inside "kimchi juice" does not."""
    if gram is None or whole is None:
        return False
    return gram.canonical_name == whole.canonical_name or (
        whole.canonical_name in gram.ambiguous_with
    )


def _spans(text: str, phrases: Sequence[str]) -> list[tuple[int, int]]:
    """Non-overlapping case-insensitive word-bounded matches, longest phrase first. Matching is
    on the original text (``re.IGNORECASE``), so offsets always line up with it."""
    taken: list[tuple[int, int]] = []
    for phrase in phrases:
        pattern = rf"(?<![A-Za-z0-9]){re.escape(phrase)}(?![A-Za-z0-9])"
        for m in re.finditer(pattern, text, re.IGNORECASE):
            span = (m.start(), m.end())
            if any(span[0] < e and s < span[1] for s, e in taken):
                continue
            taken.append(span)
    return sorted(taken)


def _overlaps(span: tuple[int, int], others: Sequence[tuple[int, int]]) -> bool:
    """True when a mention of another ingredient at least as long covers part of ``span``."""
    s, e = span
    return any(os < e and s < oe and (oe - os) >= (e - s) for os, oe in others)


def _cased(replacement: str, matched: str) -> str:
    if matched[:1].isupper() and replacement[:1].islower():
        return replacement[:1].upper() + replacement[1:]
    return replacement


_CAUTION_RE = re.compile(
    r"^\W*(?:warning|caution|important|careful|note|never|do not|don'?t|dont)\b", re.IGNORECASE
)
_SENTENCE_SPAN_RE = re.compile(r"[^.!?]+[.!?]*")


def _protected(text: str) -> list[tuple[int, int]]:
    """Caution sentences ("Do not …", "Warning: …") are never rewritten, only annotated."""
    return [
        (m.start(), m.end())
        for m in _SENTENCE_SPAN_RE.finditer(text)
        if _CAUTION_RE.match(m.group(0))
    ]


def _inside(span: tuple[int, int], ranges: Sequence[tuple[int, int]]) -> bool:
    return any(s <= span[0] and span[1] <= e for s, e in ranges)


def _extends_into_other_food(
    text: str, span: tuple[int, int], target: str, dictionary: IngredientDictionary
) -> bool:
    """ "egg" in "egg noodles", "garlic" in "garlic powder", "chicken" in "chicken stock"."""
    after = re.match(r"\s+([A-Za-z'-]+)", text[span[1] :])
    before = re.search(r"([A-Za-z'-]+)\s+$", text[: span[0]])
    phrase = text[span[0] : span[1]].lower()
    for longer in (
        f"{phrase} {after.group(1).lower()}" if after else None,
        f"{before.group(1).lower()} {phrase}" if before else None,
    ):
        if longer is None:
            continue
        entry = known_food(longer, dictionary)
        if entry is not None and entry.canonical_name != target:
            return True
    return False


def _clean_ratio(spec: AdaptationSpec) -> bool:
    """A ratio that reads as a plain amount of the replacement ("1 tbsp butter")."""
    ratio = (spec.ratio_or_amount or "").strip()
    if not ratio or len(ratio) > 80 or not re.match(r"^(?:\d|½|¼|¾|a |an |about )", ratio):
        return False
    if re.search(r"\bper\b|of the amount|:|%|\bratio\b", ratio, re.IGNORECASE):
        return False
    first = spec.replacement.split(" ")[0].lower().strip(",")
    return first in ratio.lower()


def annotation(spec: AdaptationSpec, *, with_ratio: bool = False) -> str:
    if with_ratio and spec.ratio_or_amount:
        return (
            f"(Swap: use {spec.replacement} instead of the {spec.original}: "
            f"{spec.ratio_or_amount}.)"
        )
    return f"(Swap: use {spec.replacement} instead of the {spec.original}.)"


def adapt_step(
    step: StepOut,
    specs: Sequence[AdaptationSpec],
    ingredients: dict[str, IngredientOut],
    dictionary: IngredientDictionary,
) -> tuple[str, list[str]]:
    """The step's session text with every applicable swap, and the adaptation ids applied.

    * Steps whose ``ingredient_refs`` include the swapped ingredient get mention-replacement (or
      an annotation when the step never names it). Every other recipe ingredient is a rival, and
      a match that is part of a longer food ("egg noodles", "chicken stock", "garlic powder") is
      left alone.
    * Where the step states an amount ("2 tbsp of the mirin"), the whole amount + name becomes
      the swap's ``ratio_or_amount`` once; if the ratio is not a plain amount, the name is
      replaced and one annotation carries the ratio.
    * Caution sentences ("Do not …", "Warning: …") are never rewritten; they get an annotation.
    * Steps that name the ingredient without referencing it get an annotation only."""
    text = step.instruction
    tagged = [s for s in specs if s.ingredient_ref in step.ingredient_refs]
    untagged = [s for s in specs if s.ingredient_ref not in step.ingredient_refs]
    swapped_refs = {s.ingredient_ref for s in specs}
    rivals: list[tuple[int, int]] = []
    for ref, ing in ingredients.items():
        if ref not in swapped_refs:
            rivals += _spans(text, mention_phrases(ing.name, dictionary))
    protected = _protected(text)

    def phrases_for(spec: AdaptationSpec) -> list[str]:
        name = ingredients[spec.ingredient_ref].name if spec.ingredient_ref in ingredients else ""
        return mention_phrases(name or spec.original, dictionary)

    def target_of(spec: AdaptationSpec) -> str:
        name = ingredients[spec.ingredient_ref].name if spec.ingredient_ref in ingredients else ""
        entry = normalize(name or spec.original, dictionary).entry
        return entry.canonical_name if entry is not None else clean(name or spec.original)

    def usable(spec: AdaptationSpec, edits: list[tuple[int, int, str]]) -> list[tuple[int, int]]:
        taken = rivals + [(s, e) for s, e, _ in edits]
        return [
            span
            for span in _spans(text, phrases_for(spec))
            if not _overlaps(span, taken)
            and not any(s < span[1] and span[0] < e for s, e, _ in edits)
            and not _extends_into_other_food(text, span, target_of(spec), dictionary)
        ]

    edits: list[tuple[int, int, str]] = []
    notes: list[tuple[AdaptationSpec, bool]] = []
    applied: list[str] = []
    for spec in tagged:
        applied.append(spec.id)
        found = usable(spec, edits)
        editable = [sp for sp in found if not _inside(sp, protected)]
        if not editable:
            notes.append((spec, False))
            continue
        amount_used = False
        for s_, e_ in editable:
            window_start = max(0, s_ - 40)
            amount = _AMOUNT_BEFORE_RE.search(text[window_start:s_])
            if amount and not amount_used:
                amount_used = True
                if _clean_ratio(spec):
                    edits.append((window_start + amount.start(), e_, spec.ratio_or_amount or ""))
                    continue
                if spec.ratio_or_amount:
                    notes.append((spec, True))  # one annotation with the ratio, never per mention
            edits.append((s_, e_, spec.replacement))
        if len(editable) < len(found):
            notes.append((spec, False))  # also named inside a caution sentence

    for spec in untagged:
        if usable(spec, edits):
            notes.append((spec, False))
            applied.append(spec.id)

    if not applied:
        return step.instruction, []
    out: list[str] = []
    cursor = 0
    for s_, e_, replacement in sorted(edits):
        out.append(text[cursor:s_])
        out.append(_cased(replacement, text[s_:e_]))
        cursor = e_
    out.append(text[cursor:])
    adapted = "".join(out)
    seen: set[str] = set()
    tail: list[str] = []
    for spec, with_ratio in notes:
        note = annotation(spec, with_ratio=with_ratio)
        if spec.id in seen and not with_ratio:
            continue
        if note not in tail:
            tail.append(note)
        seen.add(spec.id)
    if tail:
        adapted = " ".join([adapted.rstrip(), *tail])
    return adapted, applied


def compose_overlay(
    steps: Sequence[StepOut],
    ingredients: Sequence[IngredientOut],
    specs: Sequence[AdaptationSpec],
    dictionary: IngredientDictionary,
) -> dict[str, dict[str, object]]:
    """``{step_id: {"instruction", "adaptation_ids"}}`` for every adapted step."""
    by_id = {i.id: i for i in ingredients}
    overlay: dict[str, dict[str, object]] = {}
    for step in steps:
        text, ids = adapt_step(step, specs, by_id, dictionary)
        if ids:
            overlay[step.id] = {"instruction": text, "adaptation_ids": ids}
    return overlay


# --------------------------------------------------------------------------- timer suggestions

_DURATION_RE = re.compile(
    r"(?P<prev>\b[a-z]+\s+)?(?P<a>\d+)(?:\s*(?:to|-|\u2013|or)\s*(?P<b>\d+))?\s*"
    r"(?P<unit>hours?|hrs?|minutes?|mins?|seconds?|secs?)\b(?!\s+(?:less|more|longer)\s+than)",
    re.IGNORECASE,
)
_SKIP_PREV = {"within", "than", "every", "up", "per", "after"}
_LABELS = (
    ("marinate", "Marinate"),
    ("simmer", "Simmer"),
    ("rest", "Rest"),
    ("drain", "Drain"),
    ("boil", "Boil"),
    ("bake", "Bake"),
    ("roast", "Roast"),
    ("steam", "Steam"),
    ("soak", "Soak"),
    ("chill", "Chill"),
    ("fry", "Fry"),
    ("cook", "Cook"),
    ("sit", "Rest"),
)
MIN_SUGGESTED_SECONDS = 60
MAX_TIMER_SECONDS = 24 * 3600


def suggested_timer(instruction: str, order: int) -> dict[str, object] | None:
    """A timer the app may *offer* ("Start a 10-min simmer timer?"); never started by itself.

    Taken from an explicit duration in the step text (the lower bound of a range, so the cook
    checks early); "within 30 minutes" and "2 minutes less than" are not timers.
    """
    for m in _DURATION_RE.finditer(instruction):
        prev = (m.group("prev") or "").strip().lower()
        if prev in _SKIP_PREV:
            continue
        unit = m.group("unit").lower()
        factor = 3600 if unit.startswith(("hour", "hr")) else 60 if unit.startswith("min") else 1
        seconds = int(m.group("a")) * factor
        if seconds < MIN_SUGGESTED_SECONDS or seconds > MAX_TIMER_SECONDS:
            continue
        lowered = instruction.lower()
        label = next(
            (lbl for word, lbl in _LABELS if re.search(rf"\b{word}", lowered)),
            f"Step {order + 1}",
        )
        return {"label": label, "duration_seconds": seconds}
    return None
