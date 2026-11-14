# Language models on the phone: tested, not shipped (2026-11-14)

Could small language models, run by llama.cpp on the phone, (a) do Summarise, Tidy up and recordings' summaries
offline, or (b) replace Desert Ant's Title, Gist and Emo for a note's front matter and its tasks' emoji? Neither
held up, so Docket runs no language model on the phone: AI on notes needs a model server (Settings › AI), and the
front matter stays with Title (title, description), Gist (tags) and Emo (emoji).

All on Liquid AI's QAD-Q4_0 GGUFs (Q4_0 is fastest on ARM), with each model card's sampling (temperature 0.1,
top-k 50, repetition penalty 1.05 for LFM2.5, 1.1 for LFM3), on the host's llama.cpp b12318 (CPU) for quality and a
OnePlus 9 Pro (Snapdragon 888) for speed.

## (a) Summarise, Tidy up, recording summaries

Five notes: a messy typed trip note with a `[[link]]`, `#tags` and tasks; a rambling voice memo; reading notes; a
three-speaker meeting transcript; a Spanish voice memo; later a plain note with no links or tags.

| Model | Size | Result |
|---|---|---|
| LFM3 1.7B (thinking off) | 1.05 GB | Good: facts, times, tags, tasks and the summary layout kept. Slips: `[[Marta]]` as `[Marta]`; the Spanish summary in English in some runs; on a note with no links it wrote "[[link]] (as needed)" and "#task: …", echoing the prompt. Worked on the phone (first answer 14.7 s with loading). Dropped: not every phone can run a 1.7B model. |
| LFM2.5 1.2B Instruct | 0.70 GB | Summaries fine, but in every prompt variant Tidy up moved a flight from 7:40 to 6:40, added things ("classic Lisbon treat", "#spelling #clarification", "please confirm") or wrapped the note in chat ("Okay, here's the revised note"). Dropped. |
| LFM2.5 350M, 230M | 0.22, 0.15 GB | Invented content: a memo turned into made-up `[[links]]`; "Travel tips" sections; action items "- [who] who". Dropped. |

What the prompts taught (kept for the server, `lib/core/ai/prompts.dart`): Liquid's cards and docs use a one-line
role as the system message and a short, precise task before the content as the user's (their meeting model:
"You are an expert meeting analyst. Analyze the transcript carefully and provide clear, accurate information based
on the content."). That beat one long system message; longer rule lists made the models worse, and naming syntax
(`[[link]]`, `#tag`) in the task made small models write it into notes that had none.

## (b) Front matter and emoji: LFM2.5 230M / 350M against Desert Ant

Title's 14 test passages (six languages) and 16 tasks. Each field asked for on its own, or all at once as JSON held
to a schema by llama.cpp's grammar (the only form that kept its shape: asked separately, both models prefixed
"Title:", answered "topic1, topic2, topic3", copied the note as its description, or echoed the instructions).

| Field | Desert Ant (phone) | LFM2.5 230M / 350M, batched JSON (host) |
|---|---|---|
| Tags | Gist, 15 to 40 ms: `home-garden` 0.82 for a garden plan, `food-drink` 0.99 for a recipe, `technology` 0.92 for a French app meeting, `news-politics` for a council vote | Held to Gist's 36 topics: `gaming` ×3 for the garden plan, `music` for a client presentation, `crafts-hobbies` for a park, `business` for a cake |
| Emoji | Emo, 16/16: 🦷 dentist (and "Zahnarzttermin"), 🏋️ gym, ✈️ flights, 🚪 squeaky door, 🎁 present, 👔 dry cleaning | 6 of 16 not an emoji ("dentist", "book", "water", "dry"); 👁️ for a dentist, 🛋️ for a door |
| Title | Title (Granite 4.0 350M, fine-tuned), 1.6 to 3.3 s: specific ("City council approves 40-acre public park"); a few slips | Even, 3 to 4 times faster: in the note's language ("Fuga del baño", "Heizung im Kinderzimmer"), but generic at times ("Notiz für morgen") and the long memo titled after a tangent ("Office Move Discussion") |
| Description | Title: one or two specific sentences; a Japanese one cut off | Worse: the first sentence copied, or invented ("a dairy-based diet", "medium-cooked corn") |

Naming the language helped little; the schema mattered most. A fine-tune (as Title is of Granite) is what a small
model needs for these jobs, not a prompt.
