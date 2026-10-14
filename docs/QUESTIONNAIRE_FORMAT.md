# Steady questionnaire format

Questionnaires and exercises are JSON. You can build them in the app, upload a file, or import from a FHIR Questionnaire or the ReproSchema library (both are converted to this format). The server validates every definition (`server/pb_hooks/lib/core.js`, `validateInstrument`) and explains any problem.

## Questionnaire

```json
{
  "key": "session-feedback",
  "name": "Session feedback",
  "fullName": "Post-session feedback",
  "kind": "questionnaire",
  "summary": "3 questions, about a minute",
  "instructions": "Thinking about today's session:",
  "responseSets": {
    "agree": [
      { "label": "Disagree", "value": 0 },
      { "label": "Neutral", "value": 1 },
      { "label": "Agree", "value": 2 }
    ]
  },
  "items": [
    { "id": "heard", "text": "I felt heard", "responseSet": "agree" },
    { "id": "goals", "text": "We worked on what I wanted to work on", "responseSet": "agree" },
    { "id": "worse", "text": "Did anything make you feel worse?", "type": "choice",
      "options": [ { "label": "No", "value": 0 }, { "label": "Yes", "value": 1 } ] },
    { "id": "what", "text": "What made you feel worse?", "type": "text", "required": true,
      "showIf": { "anyOf": [ { "item": "worse", "op": "=", "value": 1 } ] } }
  ],
  "scoring": {
    "method": "sum",
    "items": ["heard", "goals"],
    "bands": [
      { "min": 0, "max": 1, "label": "Low alliance", "severity": "warn" },
      { "min": 2, "max": 4, "label": "OK", "severity": "none" }
    ],
    "itemFlags": [
      { "item": "worse", "op": "=", "value": 1, "label": "Felt worse after session", "severity": "alert" }
    ]
  },
  "licence": { "name": "Written by the practice", "status": "custom" }
}
```

### Fields

| Field | Required | Notes |
|---|---|---|
| `key` | yes | 2 to 60 lowercase letters, digits, `-` or `_`. Unique in the library. |
| `name` | yes | Short name shown everywhere. |
| `kind` | yes | `questionnaire` or `exercise`. |
| `items[].id` | yes | Unique within the questionnaire. Answers are stored against it, so don't change ids once in use. |
| `items[].type` | | `choice` (default), `text` or `number` (`min`, `max`). |
| `items[].options` or `responseSet` | for choice | Options are `{label, value}` with numeric values. |
| `items[].required` | | Default `true`. |
| `items[].showIf` | | Show the item only when any condition holds. Conditions refer to earlier items; `op` is `>`, `>=`, `=`, `<` or `<=`. Hidden items are never required. |
| `scoring.method` | | `sum` (default) or `mean`. |
| `scoring.items` | | Which items count. Default: all choice and number items. |
| `scoring.multiplier` | | E.g. 4 for WHO-5. |
| `scoring.bands` | | `{min, max, label, severity}` on the final score. |
| `scoring.subscales` | | `{id, label, items, max}`, reported alongside the total. |
| `scoring.itemFlags` | | Flag single answers for review, e.g. PHQ-9 item 9. |
| `severity` | | `none`, `info`, `warn` (amber) or `alert` (red). |
| `licence.status` | | Set by the server: `cleared`, `review`, `blocked` or `custom`. |

## Exercises

```json
{ "key": "box-breathing", "name": "Box breathing", "kind": "exercise",
  "exercise": { "type": "breathing", "rounds": 6, "phases": [
    { "label": "Breathe in", "seconds": 4, "expand": true },
    { "label": "Hold", "seconds": 4, "expand": true },
    { "label": "Breathe out", "seconds": 4, "expand": false },
    { "label": "Hold", "seconds": 4, "expand": false } ] } }
```

```json
{ "key": "grounding", "name": "5-4-3-2-1 grounding", "kind": "exercise",
  "exercise": { "type": "steps", "steps": [
    { "title": "5 things you can see", "prompt": "Look around slowly..." } ] } }
```

Phase seconds must be 1 to 30; rounds 1 to 60.

## Importing

- **FHIR**: an R4 or R5 `Questionnaire` resource. Groups are flattened; `choice` answers take their score from the `ordinalValue` or `itemWeight` extension, a numeric code, or their position. Licence defaults to "Check licence".
- **ReproSchema**: by activity name (e.g. `PHQ-9`, `GAD7`, `PC-PTSD-5`). The server fetches the files from GitHub, converts conditional display rules of the form `a === 1` or `a > 0 || b > 0`, and turns a simple sum in `compute` into scoring. More complex rules are dropped and those items become optional.
