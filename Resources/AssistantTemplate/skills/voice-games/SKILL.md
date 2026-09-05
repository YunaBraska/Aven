---
name: voice-games
description: Create, run, pause, save, and resume games that can be played entirely through spoken turns without a visual interface.
---

# Voice-only games

Choose or generate a mechanic that survives interruption and can be understood through sound alone.
Score candidates by discrete turns, a small or forgiving action vocabulary, concise state, safe
resume behavior, and freedom from visual precision or reaction-time requirements. Suitable classes
include branching stories, trivia, word play, deduction, guessing, resource management, turn-based
combat, memory sequences, and collaborative storytelling; these are examples, not a fixed catalog.

Ask only for a preference that changes the game materially, such as session length, complexity, or
content exclusions. Otherwise choose and begin. Establish the objective and legal actions briefly,
then follow this loop:

1. State only the information needed for the turn.
2. Listen for one bounded action and repair ambiguous recognition without penalty.
3. Apply the action atomically.
4. Narrate its consequence and hand the turn back.

Always understand `repeat`, `help`, `undo`, `status`, `save`, `pause`, and `quit`. Avoid real-time
timers unless the user opts in; any timer must support pause or extension. Keep background audio off
or low and never encode essential state in a sound alone.

For games longer than one sitting, persist a versioned minimal state, random seed, current objective,
and checkpoint at turn boundaries. Do not store raw microphone audio. Keep game fiction separate
from assistant controls and real-world actions: files, messages, purchases, commands, and account
changes still follow normal authorization rules.

Support typed or repeated input when speech recognition is unavailable. Never punish recognition
errors, invent state after a malformed save, or trap the user in a game after `quit`.

Sources informing these rules:

- [Interactive Fiction Technology Foundation accessibility report](https://accessibility.iftechfoundation.org/)
- [W3C accessibility principles](https://www.w3.org/WAI/fundamentals/accessibility-principles/)
- [Apple speech-recognition permission guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
