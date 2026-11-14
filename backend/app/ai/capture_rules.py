"""Deterministic capture interviewer and transcript extractor for ``AI_PROVIDER=mock`` (brief 014).

Rule based and crude on purpose: it keeps capture usable end to end with AI off, and it never
invents anything. A quantity or time is only filled when the creator said a number for it;
otherwise it stays empty and is listed in ``unknowns``.

Interviewer rules (each on one utterance):
* oven / bake / roast with no temperature → "What temperature is the oven?";
* fry / sear / sauté with no heat level → "What heat do you use?";
* simmer / boil / bake / … with no duration → "How long do you let it simmer?";
* an ingredient with no amount in front of it → "How much tofu do you use?";
* "until it's done" → "How do you know when it's ready?"; cutting with no size → "How do you
  cut it?"; after Done, no "serves N" anywhere → "How many people does this feed?".
"""

from __future__ import annotations

import re

from app.ai.providers.base import (
    CaptureFact,
    CaptureInterviewRequest,
    CaptureUtterance,
    ExtractedIngredient,
    ExtractedRecipeDraft,
    ExtractedStep,
    GapDecision,
    GapProposal,
    TranscriptExtractionRequest,
)
from app.domains.capture.policy import LIVE_TOPICS, TOPIC_RANK, parse_command

_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
    "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    "a": 1, "an": 1, "half": 0.5, "half a": 0.5, "half an": 0.5,
}  # fmt: skip
_NUM = r"(?:\d+(?:\.\d+)?|half an?|" + "|".join(sorted(_WORDS, key=len, reverse=True)) + ")"
_VAGUE_NUM = r"(?:a few|a couple of|a couple|few|several|some)"
_DURATION_RE = re.compile(
    rf"\b(?P<n>{_NUM}|{_VAGUE_NUM})\s+(?:more\s+)?(?P<u>seconds?|secs?|minutes?|mins?|hours?|hrs?)\b"
)
_TEMP_RE = re.compile(
    r"(\d+\s*(?:°|degrees?|deg\b|c\b|f\b))|°|\bgas mark\b|"
    r"\b(?:low|medium|high|medium-high|medium-low|full|gentle|max)\s+(?:heat|flame|fire)\b"
)
_UNITS = (
    "cups? tbsp tablespoons? tsp teaspoons? g grams? kg kilos? ml l litres? liters? cloves? "
    "blocks? cans? pieces? slices? pinch(?:es)? bunch(?:es)? stalks? lbs? pounds? oz ounces? "
    "spoons? spoonfuls? handfuls?"
).split()
_UNIT = r"(?:" + "|".join(_UNITS) + r")"
_FOODS = (
    "pork belly", "kimchi juice", "kimchi", "tofu", "onion", "garlic", "gochugaru", "gochujang",
    "spring onion", "green onion", "scallion", "anchovy stock", "stock", "water", "sugar", "salt",
    "soy sauce", "fish sauce", "sesame oil", "oil", "butter", "flour", "egg", "milk", "rice",
    "chicken", "beef", "potato", "carrot", "ginger", "black pepper", "mushroom", "noodles",
    "tuna", "zucchini", "courgette", "cabbage", "chili",
)  # fmt: skip
_TIME_VERBS = ("simmer", "boil", "bake", "roast", "fry", "steam", "rest", "marinate", "braise")
_HEAT_VERBS = ("fry", "sear", "saute", "sauté", "brown")
_ACTION_RE = re.compile(
    r"\b(add|adding|put|goes in|go in|pour|stir|mix|simmer|boil|fry|sear|saut[eé]|bake|roast|"
    r"chop|cut|slice|dice|season|serve|cook|steam|rest|marinate|braise|heat|drop|throw|tip)\b"
)
_NOTE_RE = re.compile(
    r"\b(my mum|my mom|mum always|always|never|the secret|the trick|make sure|don't)\b"
)
_SERVES_RE = re.compile(
    r"\b(serves|feeds|enough for)\s+\w+|\b\w+\s+(people|servings|portions|bowls)\b"
)
_LEAD_RE = re.compile(r"^(?:(?:okay|ok|so|and|now|then|first|next|right|um|uh)[,\s]+)+", re.I)


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower().replace(chr(0x2019), "'")).strip()


def _number(word: str) -> float | None:
    word = word.strip().lower()
    if re.fullmatch(r"\d+(?:\.\d+)?", word):
        return float(word)
    return _WORDS.get(word)


def duration_minutes(text: str) -> int | None:
    """Minutes from the first stated duration ("fifteen minutes", "half an hour"), or None."""
    m = _DURATION_RE.search(_norm(text))
    if m is None:
        return None
    n = _number(m["n"])
    if n is None:
        return None
    unit = m["u"]
    minutes = n * 60 if unit.startswith(("hour", "hr")) else n / 60 if unit.startswith("s") else n
    return max(round(minutes), 0) or None


def _slug(food: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", food).strip("_")


def foods_in(text: str) -> list[str]:
    """Ingredients named in ``text``, longest name first, skipping "no oil"."""
    norm, found = _norm(text), []
    taken: list[tuple[int, int]] = []
    for food in _FOODS:
        for m in re.finditer(rf"\b{re.escape(food)}(?:e?s)?\b", norm):
            if any(a < m.end() and m.start() < b for a, b in taken):
                continue
            taken.append((m.start(), m.end()))
            if re.search(r"\b(?:no|without)\s+(?:\w+\s+)?$", norm[: m.start()]):
                continue
            if food not in found:
                found.append(food)
    return found


_UNIT_NAMES = {
    "gram": "g", "grams": "g", "kilo": "kg", "kilos": "kg", "litre": "l", "litres": "l",
    "liter": "l", "liters": "l", "tablespoon": "tbsp", "tablespoons": "tbsp",
    "teaspoon": "tsp", "teaspoons": "tsp", "cups": "cup", "cloves": "clove", "pound": "lb",
    "pounds": "lb", "lbs": "lb", "ounce": "oz", "ounces": "oz",
}  # fmt: skip


# Words that may sit between an amount and the food ("two *big* onions"), never a time unit,
# a vague word or a verb: "simmer for two minutes, add tofu" states no tofu amount.
_NOT_ADJ = (
    r"(?:seconds?|secs?|minutes?|mins?|hours?|hrs?|degrees?|of|and|then|add|adding|put|in|"
    r"into|with|goes|go|it|the|a|an|plus|or|more|lot|lots|bit|little|few|some|for|until)"
)
_ADJ = rf"(?!{_NOT_ADJ}\b)[a-z][a-z'-]*"
# A bare count needs a real number: "a" / "an" only count when a unit follows ("a spoon of").
_COUNT = (
    r"(?:\d+(?:\.\d+)?|half an?|"
    + "|".join(sorted((w for w in _WORDS if w not in ("a", "an")), key=len, reverse=True))
    + ")"
)


def stated_quantity(text: str, food: str) -> tuple[float, str | None] | None:
    """The amount the creator said for ``food``, or None. The number must sit right next to a
    unit ("two cups of kimchi", "a spoon of gochugaru") or the food itself ("two onions",
    "three big eggs"); it is never borrowed from a time phrase or a vague word."""
    norm = _norm(text)
    food_re = rf"{re.escape(food)}(?:e?s)?\b"
    with_unit = re.search(
        rf"\b(?P<n>{_NUM})\s+(?P<u>{_UNIT})\s+(?:of\s+)?(?:the\s+)?(?:{_ADJ}\s+)?{food_re}",
        norm,
    )
    bare = with_unit or re.search(rf"\b(?P<n>{_COUNT})\s+(?:{_ADJ}\s+)?{food_re}", norm)
    if bare is None:
        return None
    n = _number(bare["n"])
    raw_unit = bare.groupdict().get("u")
    unit = _UNIT_NAMES.get(raw_unit, raw_unit) if raw_unit else None
    return (n, unit) if n else None


def _gaps_for(text: str) -> tuple[list[GapProposal], list[str]]:
    """(new gaps, filled topic_keys) for one utterance."""
    norm = _norm(text)
    gaps: list[GapProposal] = []
    filled: list[str] = []
    has_temp = _TEMP_RE.search(norm) is not None
    oven = re.search(r"\b(oven|bake|baking|roast)\b", norm) is not None
    if oven:
        (filled if has_temp else gaps).append(
            "oven_temperature"
            if has_temp
            else GapProposal(
                topic_key="oven_temperature",
                topic="temperature",
                question="What temperature is the oven?",
            )
        )
    for verb in _HEAT_VERBS:
        if re.search(rf"\b{verb}", norm) and not oven:
            key = f"{_slug(verb)}_heat"
            if has_temp:
                filled.append(key)
            else:
                gaps.append(
                    GapProposal(
                        topic_key=key, topic="temperature", question="What heat do you use?"
                    )
                )
            break
    has_duration = _DURATION_RE.search(norm) is not None
    for verb in _TIME_VERBS:
        if re.search(rf"\b{verb}", norm):
            key = f"{verb}_time"
            if has_duration:
                filled.append(key)
            else:
                q = f"How long do you let it {verb}?"
                gaps.append(GapProposal(topic_key=key, topic="time", question=q))
    for food in foods_in(norm):
        key = f"{_slug(food)}_quantity"
        if stated_quantity(norm, food) is not None:
            filled.append(key)
        elif food not in ("water", "oil", "salt", "black pepper"):
            q = f"How much {food} do you use?"
            gaps.append(GapProposal(topic_key=key, topic="quantity", question=q))
    if re.search(r"\buntil (?:it'?s|its|they'?re|it is) (?:done|ready|cooked)\b", norm):
        q = "How do you know when it's ready?"
        gaps.append(GapProposal(topic_key="doneness_cue", topic="doneness", question=q))
    if re.search(r"\b(cut|chop|slice|dice)\b", norm) and not re.search(
        r"\b(into|thin|thick|bite|cm|inch|small|big|large|chunks|pieces)\b", norm
    ):
        gaps.append(GapProposal(topic_key="cut_size", topic="prep", question="How do you cut it?"))
    if _SERVES_RE.search(norm):
        filled.append("servings")
    return gaps, filled


def interview(request: CaptureInterviewRequest) -> GapDecision:
    gaps: dict[str, GapProposal] = {}
    filled: list[str] = []
    for utterance in request.window:
        if parse_command(utterance.text):
            continue
        new, done = _gaps_for(utterance.text)
        for g in new:
            gaps.setdefault(g.topic_key, g)
        filled.extend(done)
        if _DURATION_RE.search(_norm(utterance.text)) and not done:
            # A bare "about fifteen minutes" answers the newest open time question.
            open_time = [g.topic_key for g in request.known_gaps if g.topic == "time"]
            filled.extend(open_time[-1:])
    if request.final and not any(_SERVES_RE.search(_norm(u.text)) for u in request.window):
        q = "How many people does this feed?"
        gaps.setdefault("servings", GapProposal(topic_key="servings", topic="servings", question=q))
    known = [*(g.topic_key for g in request.known_gaps), *request.said_keys]
    for key in [*filled, *known]:
        gaps.pop(key, None)  # said later in the window, or already known: not a new gap
    live = [g for g in gaps.values() if g.topic in LIVE_TOPICS]
    live.sort(key=lambda g: TOPIC_RANK[g.topic])
    pick = live[0] if live and not request.final else None
    return GapDecision(
        open_gaps=list(gaps.values())[:10],
        filled_gaps=list(dict.fromkeys(filled))[:20],
        proposed_question=pick.question if pick else None,
        topic_key=pick.topic_key if pick else None,
        confidence=0.9 if pick else 0.0,
    )


# --- transcript → draft --------------------------------------------------------------------


def _sentence(text: str) -> str:
    text = _LEAD_RE.sub("", text.strip()).strip(" ,.")
    return (text[:1].upper() + text[1:] + ".") if text else ""


_TITLE_RE = re.compile(r"\b(?:making|make|cooking)\s+(.+?)(?:\s+today|[.!,]|$)", re.I)


def _title(request: TranscriptExtractionRequest) -> str | None:
    if request.title_hint:
        return request.title_hint
    for u in request.utterances[:6]:
        m = _TITLE_RE.search(u.text)
        if m:
            title = m[1].strip()
            return title[:1].upper() + title[1:]
    return None


def _speech(request: TranscriptExtractionRequest) -> list[CaptureUtterance]:
    answers = {_norm(f.answer) for f in request.facts}
    return [
        u
        for u in request.utterances
        if u.text.strip() and not parse_command(u.text) and _norm(u.text) not in answers
    ]


def extract(request: TranscriptExtractionRequest) -> ExtractedRecipeDraft:
    utterances = _speech(request)
    ingredients: dict[str, ExtractedIngredient] = {}
    steps: list[tuple[int, ExtractedStep]] = []
    notes: list[str] = []
    for u in utterances:
        if _TITLE_RE.search(u.text) and not _ACTION_RE.search(_norm(u.text)):
            continue  # "today I'm making kimchi jjigae" names the dish, not an ingredient
        for food in foods_in(u.text):
            amount = stated_quantity(u.text, food)
            current = ingredients.get(food)
            if current is None or (current.quantity is None and amount is not None):
                ingredients[food] = ExtractedIngredient(
                    id=current.id if current else f"ing-{len(ingredients) + 1}",
                    name=food,
                    quantity=amount[0] if amount else None,
                    unit=amount[1] if amount else None,
                    evidence_text=u.text[:300],
                    confidence=0.6,
                    needs_review=amount is None,
                )
        if _ACTION_RE.search(_norm(u.text)):
            refs = [ingredients[f].id for f in foods_in(u.text) if f in ingredients]
            steps.append(
                (
                    u.t_ms,
                    ExtractedStep(
                        id=f"step-{len(steps) + 1}",
                        order=len(steps),
                        instruction=_sentence(u.text),
                        ingredient_refs=refs,
                        estimated_minutes=duration_minutes(u.text),
                        evidence_text=u.text[:300],
                        confidence=0.5,
                    ),
                )
            )
        elif _NOTE_RE.search(_norm(u.text)) and len(notes) < 6:
            notes.append(u.text.strip())
    servings = _fold_facts(request.facts, ingredients, steps)
    unknowns = [
        f"Amount of {i.name} not stated" for i in ingredients.values() if i.quantity is None
    ]
    for _t, step in steps:
        verb = next((v for v in _TIME_VERBS if re.search(rf"\b{v}", _norm(step.instruction))), None)
        if verb and step.estimated_minutes is None:
            unknowns.append(f"How long to {verb} wasn't said")
    unknowns += [f"Not answered: {q}" for q in request.unanswered]
    return ExtractedRecipeDraft(
        title=_title(request),
        servings=servings,
        ingredients=list(ingredients.values()),
        steps=[s for _t, s in steps],
        unknowns=unknowns[:20],
        confidence=0.5,
        requires_review=True,
        creator_notes=notes,
    )


def _fold_facts(
    facts: list[CaptureFact],
    ingredients: dict[str, ExtractedIngredient],
    steps: list[tuple[int, ExtractedStep]],
) -> int | None:
    """Answers become facts in the creator's own words; a number is used only if she said it."""
    servings: int | None = None
    for fact in facts:
        answer = fact.answer.strip()
        if fact.topic == "servings":
            m = re.search(rf"\b({_NUM})\b", _norm(answer))
            n = _number(m[1]) if m else None
            servings = int(n) if n and n >= 1 else servings
            continue
        if fact.topic == "quantity":
            food = next((f for f in ingredients if f"{_slug(f)}_quantity" == fact.topic_key), None)
            amount = stated_quantity(f"{answer} {food}", food) if food else None
            if food and amount:
                ingredients[food] = ingredients[food].model_copy(
                    update={
                        "quantity": amount[0],
                        "unit": amount[1],
                        "needs_review": False,
                        "evidence_text": answer[:300],
                    }
                )
            continue
        before = [s for t, s in steps if fact.t_ms is None or t <= fact.t_ms]
        target = before[-1] if before else (steps[-1][1] if steps else None)
        if target is None:
            continue
        if fact.topic == "doneness":
            target.success_cues.append(answer)
        else:
            target.instruction = f"{target.instruction.rstrip('.')} ({answer})."
            if fact.topic == "time" and target.estimated_minutes is None:
                target.estimated_minutes = duration_minutes(answer)
    return servings
