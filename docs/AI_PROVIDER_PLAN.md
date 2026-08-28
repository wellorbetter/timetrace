# AI Provider plan

TimeTrace keeps Local Factual Recap as the zero-account fallback, and exposes online AI as an optional enhancement.

## Recommended free online options

- Gemini Free: user signs in to Google AI Studio and creates their own Gemini API key. TimeTrace preconfigures the OpenAI-compatible endpoint and a Flash model.
- OpenRouter Free: user signs in to OpenRouter and creates their own API key. TimeTrace uses `openrouter/free` by default.

## Existing API options

- DeepSeek
- OpenAI
- OpenRouter paid/specific model
- Custom OpenAI-compatible endpoint

## OpenCode reuse

OpenCode itself is treated as a local credential source, not as a model provider. TimeTrace only reads OpenCode credentials after an explicit user action. Only `type: api` credentials are eligible; OAuth/session credentials are not imported. Imported keys stay in TimeTrace process memory and are never written by TimeTrace.

## Privacy

Diary text stays disabled for external AI by default. Aggregate activity facts can be sent only after the user enables AI. Provider-specific free-tier privacy caveats must be shown in UI.
