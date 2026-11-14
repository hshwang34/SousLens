# Family & friends test — feedback (early November 2026)

- **Session:** informal family & friends test, early November 2026
- **Recorded:** 2026-11-13
- **Format:** free-text comments, collected by the PM. 22 comments; tester count and build not recorded.
- **Status:** raw input. Nothing here changes P0 scope until the PM logs a decision in `DECISIONS.md`.

## Summary

People liked the idea and several cooked a real meal with it. The friction is in getting started and
in finding their way around. The strongest signals:

1. **Pantry setup is too much work up front** (5 comments). Testers want to start with two or three
   ingredients, not inventory the whole kitchen, and don't trust themselves to keep a list current.
2. **Photo capture is wanted, with a review step** (4). Fridge photo, and especially a quick scan of
   groceries before they're put away. Everyone who raised it wants to check the list before getting
   suggestions.
3. **Navigation and labels are unclear** (4). First launch has no obvious starting point, screens
   compete for attention, and names should explain themselves rather than need a walkthrough.
4. **Sharing means "send to my partner", not posting** (4). Send a recipe with ingredients and steps,
   get a quick yes / suggest something else, keep groups small and private, and attach personal
   notes to a shared recipe.
5. **Cooking view needs to read from the counter** (1 negative, 1 positive). Self-paced steps were
   less stressful than video, but the text is too small at arm's length.
6. **Leftovers and saved ideas** (1 each). Help with partly cooked food, and a faster route back to
   saved recipes at cooking time.

## Comments by theme

Quotes are verbatim. Two had their first word cut off in the paste; the restored word is in
[brackets].

### Positive outcomes

> "I tried this on a night when I was about to order takeout again. I had food at home but couldn't
> think of anything I wanted to make with it. Having somewhere to start helped, and I ended up
> cooking. I'd use it again for that situation."

> "Made dinner with this over the weekend and it went better than expected. My youngest ate it
> without asking for something else, which doesn't happen that often. I'll probably make the same
> thing again before I try anything new."

> "I'm pretty new to cooking, so I appreciated being able to take my time with the instructions.
> Usually I'm pausing a video with messy hands and trying to find the bit I missed. This felt less
> stressful. I still had to look a couple of things up, but I finished the meal."

> "I like the idea more than I like using it at the moment. That sounds harsh, but I kept running
> into little bits of friction that took me out of it. I did get a useful dinner idea, so I'm not
> writing it off. I just want the app to feel easier on the nights when I have no energy."

### 1. Pantry setup burden

> "I started adding what was in my kitchen and got through the fridge before I lost interest.
> There's still a whole cupboard of stuff I haven't put in. I get why you need that information, but
> it's a lot to ask before I know whether the app will be useful."

> "The pantry list sounds useful, but I know myself and I'm not going to maintain it every day. I'm
> already bad at keeping a grocery list current. If it relies on me remembering to remove every
> ingredient after cooking, it'll stop being accurate pretty quickly."

> "I didn't realize how much random stuff was in my kitchen until I tried listing it. There are
> sauces I barely use, half-open bags, and spices I've had forever. I wasn't sure how much of that I
> was supposed to include. It started feeling like I needed to organize my kitchen before I could
> use the app."

> "Typing a few ingredients is fine. Sometimes I only want help using the chicken and broccoli, and
> the rest doesn't matter. I don't want to feel like I have to document the whole kitchen first. Let
> me start small and add more if I find it helpful."

> "Most of what I need help using is already partly cooked. Half a container of rice, some roast
> chicken, vegetables from yesterday. Would the pantry stuff work for that, or is it mainly for raw
> ingredients? I'd get more use out of help with leftovers than a completely new recipe."

### 2. Photo capture

> "Can I just take a picture of what's in my fridge? I'm fine checking a list afterward and fixing a
> few things it gets wrong. Typing everything out on my phone is the part I really don't want to
> do."

> "The vegetables in the bottom drawer are basically invisible to me once I put them away. I'll buy
> more and then discover I already had some. If taking a photo helped me remember what was there,
> that alone would be useful. It wouldn't even have to suggest a full meal every time."

> "[I']d try a fridge scan, but mine is usually pretty crowded. There's stuff behind other stuff, and
> half the containers aren't see-through. I'd want to review what it found before getting
> suggestions. Otherwise I'd be wondering whether it was working from the right ingredients."

> "Could I take a picture of my groceries before I put them away? That's the one time everything is
> visible and I know what I just bought. Trying to photograph the inside of my cupboards later would
> be harder. I could see myself doing a quick scan after a shopping trip."

### 3. Navigation and clarity

> "My first time opening it, I wasn't sure where to start. I tapped around for a bit and eventually
> found something useful, but I couldn't tell you how I got there. The second visit was better,
> although I still feel like I'm missing something."

> "I like how it looks overall. There are just a few places where everything seems to be asking for
> my attention at once. When I open it hungry, I don't really want to explore the app. I want to
> figure out what I'm making."

> "[I] keep having to remember where things live in the app. Nothing is impossible to find, but I
> don't use it often enough to memorize it. Clearer names would help more than another walkthrough.
> I'd rather understand the screen while I'm looking at it."

> "I've actually enjoyed browsing when I'm not hungry. I saved a few ideas while sitting on the
> couch and tried one later in the week. That part feels nice and low pressure. I'd like it to be
> easier to get straight back to those ideas when it's time to cook."

### 4. Sharing

> "My husband and I usually decide dinner over text while we're both still at work. I'd like to send
> him something from here and have him actually see the ingredients and instructions. A screenshot
> only gets us so far, especially when he's the one stopping at the store."

> "Most of my sharing would be sending something to my partner and asking if they want it for
> dinner. I'm much less likely to post a photo afterward. A quick way for them to say yes or suggest
> something else would be useful. We spend a surprising amount of time having that conversation."

> "I'd be interested in seeing friends' meals, but I wouldn't want everything I do to be public. Some
> nights dinner is whatever I managed to throw together, and I'm not trying to show that to
> everyone. Let me choose when I share something. A small private group would probably suit me
> better."

> "My mom never makes a recipe exactly as written. She'll swap something, skip a step, and then tell
> me about it afterward when mine tastes different. If she shared recipes here, I'd want her notes
> attached. The original recipe is only half the information I need."

### 5. Cooking view

> "I leave my phone on the counter while I cook, and some of the text was a little small from there.
> I kept picking it up to check what came next. That's annoying once my hands are wet or covered in
> food. A simpler view with bigger instructions would help."

## Notes for the PM

These are observations, not decisions.

- **Pantry is optional, not a gate.** Several comments assume a full pantry is needed before
  suggestions appear. Letting "chicken and broccoli" be enough would answer four of them.
- **Capture fits existing invariants.** Every capture request already asks for a review step, which
  matches "candidate/observation records are never pantry truth". A post-shopping grocery scan is a
  lower-difficulty first target than an inside-the-fridge scan.
- **Don't make pantry upkeep the user's job.** Accuracy decay after cooking is a known worry, but
  any automatic decrement would still need user confirmation (no silent state changes).
- **Leftovers** (cooked rice, roast chicken) are not covered by the PRD's pantry model today.
- **Sharing** as "send to one person, get a yes/no" is a different feature from a social feed. The
  feedback favours the former. Recipe notes from the sharer overlap with creator variations.
- **Counter-distance cooking view**: likely a type-size / layout pass on the cooking screen, worth
  checking against the calm cooking work.
